// url-extract.mjs — URL 취득부터 raw-sources/<subdir>/fetched/<slug>.md 저장까지의 orchestrator
//
// 설계서 §4.2 §4.6 §6 — idempotency + refresh_days + frontmatter 를 1 함수로 집약.
//
// 하드닝 방침 (plan p3 Task 5.2 지시서):
//   H1. assertInsideRawSourcesSubdir 로 subdir injection (예: "../wiki") 과
//       realpath+boundary check 를 강제한다.
//   H2. parseFrontmatter / serializeFrontmatter 를 사용하여, 정규식 기반의
//       frontmatter 파서와 수제 YAML string builder 를 폐지한다.
//   H3. atomicWrite 는 최종 쓰기 대상과 같은 디렉터리 (= 경계 검사 완료) 에서
//       tmpfile → rename.
//   H4. subdir 의 기본값은 'articles'. 임의값 수용은 호출자 측 (Phase 7).
//   H5. not_html error 에 pdfCandidate + fetchResult 를 부여하여 Phase 7 로 교량.

import { createHash } from 'node:crypto';
import { mkdir, open, readdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { JSDOM } from 'jsdom';
import { fetchUrl } from './url-fetch.mjs';
import { checkRobots } from './robots-check.mjs';
import { extractArticle } from './readability-extract.mjs';
import { htmlToMarkdown } from './html-to-markdown.mjs';
import { downloadImages, rewriteImageSrc } from './url-image.mjs';
import { llmFallbackExtract } from './llm-fallback.mjs';
import { urlToFilename } from './url-filename.mjs';
import { applyMasks } from './masking.mjs';
import { assertInsideBase, assertInsideRawSourcesSubdir } from './vault-path.mjs';
import { parseFrontmatter, serializeFrontmatter } from './frontmatter.mjs';

function envRefreshDaysDefault() {
  const raw = process.env.GIEOK_URL_REFRESH_DAYS;
  if (raw === undefined || raw === '') return 30;
  if (raw === 'never') return 'never';
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : 30;
}

/**
 * @param {object} opts
 * @param {string} opts.url
 * @param {string} opts.vault
 * @param {string} [opts.subdir='articles']
 * @param {number|string} [opts.refreshDays]
 * @param {string} [opts.title]
 * @param {string} [opts.sourceType='article']
 * @param {string[]} [opts.tags]
 * @param {string} [opts.robotsUrlOverride]
 * @param {string} [opts.claudeBin]
 * @returns {Promise<{status: string, path: string, source_sha256: string, url: string, fallback_used?: string, images?: string[], warnings?: string[]}>}
 */
export async function extractAndSaveUrl(opts) {
  const {
    url,
    vault,
    subdir = 'articles',
    title: titleOverride,
    sourceType = 'article',
    tags = [],
    robotsUrlOverride,
    claudeBin,
  } = opts;
  // refreshDays 의 취급:
  //   - 명시 지정이 없는 경우는 default 를 저장 시의 frontmatter 값으로 사용하지만, 조기 skip 에는
  //     사용하지 않는다 (= 매번 fetch 해서 sha 비교). 호출자 측이 리프레시 간격을 의도적으로
  //     지정한 경우에만 fetch 를 생략한다 (UI9/11/13/14 의 조합을 만족시키기 위해).
  const refreshDaysExplicit = Object.prototype.hasOwnProperty.call(opts, 'refreshDays');
  const refreshDays = refreshDaysExplicit ? opts.refreshDays : envRefreshDaysDefault();

  // 1. robots.txt
  await checkRobots(url, { robotsUrlOverride });

  // 2. 경계 검사가 끝난 최종 쓰기 경로를 결정한다.
  //    assertInsideRawSourcesSubdir 는 realpath 기반이므로 base (fetched/) 를
  //    먼저 mkdir -p 한 후 호출해야 한다 (H1 의 순서).
  const filename = urlToFilename(url);
  const fetchedAbs = join(vault, 'raw-sources', subdir, 'fetched');
  await mkdir(fetchedAbs, { recursive: true, mode: 0o700 });
  const finalAbs = await assertInsideRawSourcesSubdir(vault, subdir, `fetched/${filename}`);
  // 반환용 vault-relative path 는 입력으로부터 조립한다 (realpath 변환을 걸지 않음 —
  // symlink 아래에서의 흔들림을 피하기 위해). fs 조작은 모두 finalAbs 를 경유해 수행한다.
  const relativePath = `raw-sources/${subdir}/fetched/${filename}`;

  // 3. refresh_days 조기 판정 — refreshDays 가 명시 지정되었을 때만 유효.
  //    기본값 (호출자 측이 미지정) 인 경우는 fetch 해서 sha 비교에 위임한다.
  const existingFrontmatter = await tryReadFrontmatter(finalAbs);
  if (
    refreshDaysExplicit
    && existingFrontmatter
    && shouldSkipBasedOnRefresh(existingFrontmatter, refreshDays)
  ) {
    const status = isNeverPolicy(refreshDays, existingFrontmatter) ? 'skipped_never' : 'skipped_within_refresh';
    return {
      status,
      path: relativePath,
      source_sha256: existingFrontmatter.source_sha256,
      url,
    };
  }

  // 4. fetch
  const fetchResult = await fetchUrl(url, {
    accept: 'text/html,application/xhtml+xml,application/pdf;q=0.9',
  });

  // 5. Content-Type 분기 — HTML 이외는 호출자 (ingest-url.mjs Phase 7) 에서
  //    PDF dispatch 등을 판단시킨다. H5: fetchResult 를 첨부하여 다시 던진다.
  const ct = (fetchResult.contentType || '').toLowerCase();
  if (!ct.includes('text/html') && !ct.includes('application/xhtml+xml')) {
    const err = new Error(`not HTML: ${ct}`);
    err.code = 'not_html';
    err.pdfCandidate = ct.includes('application/pdf');
    err.fetchResult = fetchResult;
    throw err;
  }

  // 6. Readability → 부족하면 LLM 폴백
  const extracted = extractArticle(fetchResult.body, fetchResult.finalUrl);
  let markdown;
  let fallbackUsed;
  if (extracted.needsFallback) {
    const fb = await llmFallbackExtract({
      html: fetchResult.body,
      url: fetchResult.finalUrl,
      cacheDir: join(vault, '.cache', 'tmp'),
      claudeBin,
    });
    if (!fb.success) {
      const err = new Error(`extraction failed: ${fb.error}`);
      err.code = 'extraction_failed';
      throw err;
    }
    markdown = fb.markdown;
    fallbackUsed = 'llm_fallback';
  } else {
    markdown = htmlToMarkdown(extracted.content);
    fallbackUsed = 'readability';
  }

  // 7. 이미지 DL + rewrite (media/ 는 fetchedAbs 하위)
  const imgs = extractImgTags(fetchResult.body);
  const mediaDir = join(fetchedAbs, 'media');
  const { images, warnings } = await downloadImages(imgs, {
    baseUrl: fetchResult.finalUrl,
    mediaDir,
  });
  const mapping = new Map();
  for (const img of images) {
    try {
      mapping.set(new URL(img.src, fetchResult.finalUrl).href, img.localPath);
    } catch {
      // 무효 URL 은 매핑하지 않고 본문 안에 남긴다 (rewriteImageSrc 는 mapping miss 를
      // 그대로 보존한다)
    }
  }
  markdown = rewriteImageSrc(markdown, mapping, fetchResult.finalUrl);

  // 8. MASK_RULES — sha256 계산 전에 적용한다 (idempotency 키가 마스크 후의 본문)
  markdown = applyMasks(markdown);

  // 9. sha256 (body 만. frontmatter 는 포함하지 않음)
  const sha = createHash('sha256').update(markdown, 'utf8').digest('hex');

  // 10. idempotency: sha 일치하면 내용은 덮어쓰지 않고, fetched_at 만 bump
  if (existingFrontmatter && existingFrontmatter.source_sha256 === sha) {
    if (refreshDays === 'never') {
      return { status: 'skipped_never', path: relativePath, source_sha256: sha, url };
    }
    await bumpFetchedAt(finalAbs);
    return { status: 'skipped_same_sha', path: relativePath, source_sha256: sha, url };
  }

  // 11. frontmatter 를 구성하여 atomic write.
  //     serializeFrontmatter 는 문자열을 안전한 경우 베어 출력하지만, 본 프로젝트의
  //     frontmatter 기존 규약 (write-note/write-wiki 템플릿) 에 맞춰 문자열은
  //     항상 더블 쿼트로 감싼다. JSON.stringify 동등의 이스케이프만 사용
  //     (YAML double-quoted string 은 JSON string 의 슈퍼셋).
  const finalTitle = titleOverride || extracted.title || filename.replace(/\.md$/, '');
  const frontmatterObj = buildFrontmatterObject({
    title: finalTitle,
    source_type: sourceType,
    source_url: url,
    source_final_url: fetchResult.finalUrl,
    source_host: new URL(fetchResult.finalUrl).hostname,
    source_sha256: sha,
    fetched_at: new Date().toISOString(),
    fetched_by: 'gieok-ingest-url',
    fallback_used: fallbackUsed,
    byline: extracted.byline,
    site_name: extracted.siteName,
    published_time: extracted.publishedTime,
    og_image: extracted.ogImage,
    image_count: images.length,
    truncated: fetchResult.truncated,
    refresh_days: refreshDays,
    tags,
    warnings,
  });
  const content = serializeWithQuotedStrings(frontmatterObj, `\n${markdown}\n`);
  await atomicWrite(finalAbs, content);

  // 12. raw HTML 을 .cache/html/ 에 저장 (Phase 8 에서 재추출, debug 용도)
  //
  // 2026-04-20 MED-b1 fix: urlToFilename 의 sanitizer 단일점에 의존하던 곳에
  // `assertInsideBase` 에 의한 realpath containment check 를 이중으로 건다. 향후
  // urlToFilename 이 완화되어도 (예: `/` 허용), `.cache/html/` 경계는 여기서 강제된다.
  // urlToFilename 은 다음을 보증한다:
  //   - path 구분자 (/, ..) 는 모두 `-` 로 치환, SAFE_PATH_RE (\p{L}\p{N}/._ -) 호환
  //   - 선두 `-` 제거, 80 문자 초과 시 truncate + sha8 suffix
  const htmlCacheDir = join(vault, '.cache', 'html');
  await mkdir(htmlCacheDir, { recursive: true, mode: 0o700 });
  const htmlFilename = filename.replace(/\.md$/, '.html');
  // MED-b1: assertInsideBase 로 realpath containment 을 검증한 후 write 한다
  const htmlAbs = await assertInsideBase(vault, '.cache/html', htmlFilename);
  await atomicWrite(htmlAbs, fetchResult.body);

  return {
    status: 'fetched_and_summarized_pending',
    path: relativePath,
    source_sha256: sha,
    url,
    fallback_used: fallbackUsed,
    images: images.map((i) => i.localPath),
    warnings,
  };
}

// ---- helpers ----------------------------------------------------------

function extractImgTags(html) {
  const dom = new JSDOM(html);
  const doc = dom.window.document;
  const imgs = [];
  for (const el of doc.querySelectorAll('img')) {
    const src = el.getAttribute('src');
    if (!src) continue;
    imgs.push({ src, alt: el.getAttribute('alt') || '' });
  }
  return imgs;
}

// H2: parseFrontmatter 를 사용한다. 읽지 못함 / frontmatter 가 없는 경우는 null.
async function tryReadFrontmatter(absPath) {
  try {
    const content = await readFile(absPath, 'utf8');
    const { data } = parseFrontmatter(content);
    if (!data || Object.keys(data).length === 0) return null;
    return data;
  } catch {
    return null;
  }
}

function isNeverPolicy(refreshDays, fm) {
  return refreshDays === 'never' || fm?.refresh_days === 'never';
}

function shouldSkipBasedOnRefresh(fm, refreshDays) {
  if (!fm.source_sha256) return false;
  if (isNeverPolicy(refreshDays, fm)) return true;
  if (!fm.fetched_at) return false;
  const fetchedTime = Date.parse(fm.fetched_at);
  if (Number.isNaN(fetchedTime)) return false;
  // Clock-skew guard (code-quality HIGH-2): Mac 2 대에서 NTP 차이가 있으면
  // fetched_at 이 미래 시각으로 저장되어 ageMs 가 음수가 되고 "refreshMs 미만"으로
  // 영구 skip 하게 된다. max(0, ...) 으로 "즉시 refetch" 취급한다.
  const ageMs = Math.max(0, Date.now() - fetchedTime);
  const days = typeof refreshDays === 'number' ? refreshDays : Number(refreshDays);
  if (!Number.isFinite(days) || days < 0) return false;
  const refreshMs = days * 24 * 3600 * 1000;
  return ageMs < refreshMs;
}

async function bumpFetchedAt(absPath) {
  try {
    const content = await readFile(absPath, 'utf8');
    const { data, body } = parseFrontmatter(content);
    if (!data || Object.keys(data).length === 0) return;
    data.fetched_at = new Date().toISOString();
    const next = serializeWithQuotedStrings(data, body);
    await atomicWrite(absPath, next);
  } catch (err) {
    // 2026-04-20 LOW-c3 fix: 기존 구현은 모든 error 를 silent catch. ENOENT 은 상정 내
    // (삭제된 파일에 bump 하려 한 경우) 이지만, EACCES/EIO 등은 read-only
    // mount / disk full 의 사인이므로 operator 가시성을 위해 stderr WARN 을 낸다.
    // fetched_at 갱신 실패는 idempotency 를 sha256 으로 보증하므로 치명적이지 않지만,
    // 장기적으로 refresh_days 의 timing 이 계속 어긋나는 경로는 사전 통지할 가치가 있다.
    if (err && err.code && err.code !== 'ENOENT') {
      process.stderr.write(
        `[gieok-mcp] WARNING: bumpFetchedAt failed on ${absPath}: ${err.code}\n`,
      );
    }
  }
}

// 값이 비어있음 / null / undefined / 빈 배열은 출력 오브젝트에서 제외한다.
// insertion order 가 그대로 출력 순서가 되므로, 호출자 측에서 원하는 순서로 set 한다.
//
// MED-4 (code-quality 2026-04-19): user-controlled / HTML-derived 문자열값은
// applyMasks 를 거쳐 써낸다. tags / title / byline / site_name / source_type 을
// frontmatter 에 load 하는 경로는 지금까지 mask gate 를 통과하지 않았다 (본문 markdown 쪽만).
// Vault 가 GitHub Private repo 로 push 되므로, frontmatter 의 secret leak 은
// commit history 에 영구 잔존한다. 마스크는 idempotent 하므로 2 회 적용해도 무해.
function buildFrontmatterObject(fields) {
  const out = {};
  const setStr = (key, val) => {
    if (val === null || val === undefined || val === '') return;
    out[key] = applyMasks(String(val));
  };
  const setRaw = (key, val) => {
    if (val === null || val === undefined || val === '') return;
    if (Array.isArray(val) && val.length === 0) return;
    out[key] = val;
  };
  // user / HTML-derived: mask
  setStr('title', fields.title);
  setStr('source_type', fields.source_type);
  // source_url 은 validateUrl 에서 embedded credentials 을 사전 reject 완료이지만
  // red M-1 fix (2026-04-20): source_final_url / source_host 도 attacker-controlled 한
  // redirect chain 유래이므로 applyMasks 를 거친다 (mask 는 idempotent).
  setRaw('source_url', fields.source_url);
  if (fields.source_final_url && fields.source_final_url !== fields.source_url) {
    setStr('source_final_url', fields.source_final_url);
  }
  setStr('source_host', fields.source_host);
  setRaw('source_sha256', fields.source_sha256);
  setRaw('fetched_at', fields.fetched_at);
  setRaw('fetched_by', fields.fetched_by);
  setRaw('fallback_used', fields.fallback_used);
  // HTML 에서 수집하는 meta — Readability 경유로 site 의 지정 문자열이 그대로 들어올 수 있음
  setStr('byline', fields.byline);
  setStr('site_name', fields.site_name);
  // red M-1 fix (2026-04-20): published_time / og_image 은 <meta> tag content 속성의
  // raw 문자열. 공격 페이지가 `content="2024-01-01; ghp_..."` 처럼 secret-shaped
  // 문자열을 넣을 수 있음 → mask 필수 (mask 는 idempotent).
  setStr('published_time', fields.published_time);
  setStr('og_image', fields.og_image);
  if (typeof fields.image_count === 'number') out.image_count = fields.image_count;
  if (typeof fields.truncated === 'boolean') out.truncated = fields.truncated;
  if (fields.refresh_days !== undefined && fields.refresh_days !== null) {
    out.refresh_days = fields.refresh_days;
  }
  // tags 는 user-controlled 문자열. MED-4 fix: 각 요소를 applyMasks 로 sanitize 한다.
  if (Array.isArray(fields.tags) && fields.tags.length > 0) {
    out.tags = fields.tags.map((t) => (typeof t === 'string' ? applyMasks(t) : t));
  }
  // warnings 은 내부 생성 (downloadImages 의 결과) 이지만 만일을 위해 통과시킨다.
  if (Array.isArray(fields.warnings) && fields.warnings.length > 0) {
    out.warnings = fields.warnings.map((w) => (typeof w === 'string' ? applyMasks(w) : w));
  }
  return out;
}

// 문자열 값을 항상 더블 쿼트로 감싼 형태로 frontmatter 를 출력한다.
// - 배열은 요소마다 JSON.stringify (string) / String (비 string) 으로 직렬화
// - number / boolean 은 그대로
// - null / undefined 는 key: (빈값) 으로 출력 (호출자 측에서 제외했다는 전제지만 보험)
// JSON.stringify 가 생성하는 double-quoted 형식은 YAML double-quoted 스칼라의
// 부분집합으로 유효 (ASCII 제어, 비 ASCII 는 \uXXXX 이스케이프).
// 본 프로젝트의 YAML 재파싱측 (frontmatter.mjs) 도 JSON.parse 호환의
// strip quote + raw 수용으로 처리되므로 round-trip 이 유지된다.
function serializeWithQuotedStrings(data, body = '') {
  const lines = [];
  for (const [k, v] of Object.entries(data)) {
    if (v === null || v === undefined) {
      lines.push(`${k}:`);
    } else if (Array.isArray(v)) {
      const items = v.map((x) => (typeof x === 'string' ? JSON.stringify(x) : String(x)));
      lines.push(`${k}: [${items.join(', ')}]`);
    } else if (typeof v === 'boolean' || typeof v === 'number') {
      lines.push(`${k}: ${v}`);
    } else {
      lines.push(`${k}: ${JSON.stringify(String(v))}`);
    }
  }
  const yaml = lines.join('\n') + '\n';
  const bodyClean = body.startsWith('\n') ? body.substring(1) : body;
  return `---\n${yaml}---\n${bodyClean}`;
}

// H3: tmpfile 은 최종 디렉터리와 같은 위치에 만든다 (경계를 넘지 않음).
//
// 2026-04-20 LOW-c1 fix: SIGKILL / 디스크 full 중단 후에 남은
// `.<basename>.tmp.<pid>.<ts>` turd 를 쓰기 전에 정리한다. 해당 pid 가
// 자기 자신이 아니고 60s 이상 지난 tmp 만 unlink 한다 (동시 쓰기 중인 다른 writer 를
// 안전하게 놓친다). 실패는 silent pass.
async function atomicWrite(absPath, content) {
  const dir = dirname(absPath);
  const bname = basename(absPath);
  await garbageCollectStaleTmp(dir, bname);
  const tmp = join(dir, `.${bname}.tmp.${process.pid}.${Date.now()}`);
  const handle = await open(tmp, 'wx', 0o600);
  try {
    await handle.writeFile(content, 'utf8');
  } finally {
    await handle.close();
  }
  await rename(tmp, absPath);
}

async function garbageCollectStaleTmp(dir, bname) {
  try {
    const entries = await readdir(dir);
    const prefix = `.${bname}.tmp.`;
    const nowMs = Date.now();
    const selfPid = String(process.pid);
    for (const name of entries) {
      if (!name.startsWith(prefix)) continue;
      const tail = name.slice(prefix.length); // "<pid>.<ts>"
      const dot = tail.indexOf('.');
      if (dot < 1) continue;
      const pid = tail.slice(0, dot);
      const ts = tail.slice(dot + 1);
      if (!/^\d+$/.test(pid) || !/^\d+$/.test(ts)) continue;
      if (pid === selfPid) continue;
      if (nowMs - Number(ts) < 60_000) continue;
      try { await unlink(join(dir, name)); } catch { /* gone */ }
    }
  } catch {
    /* best effort */
  }
}
