// gieok_ingest_url — 기능 2.2 MCP tool.
//
// 설계서: plan/claude/26041801_feature-2-2-html-url-ingest-design.md §4.1 §4.7
//         plan/claude/26042102_meeting_v0-4-0-lock-refactor-decision.md (v0.4.0 refactor)
// 플로우:
//   1. URL 검증 (SSRF / scheme / credentials) — withLock 바깥에서 선행 reject
//   2. withLock(vault) — cron auto-ingest.sh / gieok_ingest_pdf와 `.gieok-mcp.lock`을 공유
//   3. fetch (binary mode)로 Content-Type 판정 + PDF size cap
//   4. robots.txt를 확인 (defense-in-depth: HTML 경로에서는 extractAndSaveUrl 내에서도 재평가)
//   5. Content-Type 분기:
//        text/html / application/xhtml+xml → extractAndSaveUrl에 위임
//        application/pdf / (octet-stream + URL 말미 .pdf) → inner 가 __pendingPdfDispatch signal
//          을 반환. outer withLock **release 후** 에 handleIngestPdf 를 호출하고, PDF 처리 측이
//          스스로 withLock 을 취득한다 (v0.4.0 Tier A#3 M-a2/M-a4)
//   6. extractAndSaveUrl이 후단에서 PDF를 감지 (리다이렉트 목적지가 PDF였던 경우 등)한 경우에도
//      err.code === 'not_html' && err.pdfCandidate === true로 PDF 경로로 rerouting.
//      이때 extractAndSaveUrl의 fetch는 **비바이너리**이므로 body는 UTF-8 문자열로
//      PDF를 유지할 수 없다. late-PDF 경로에서는 반드시 재 fetch (binary:true) 한다 (CRIT-1).
//   7. 결과 JSON을 반환
//
// v0.4.0 Tier A#3 의 lock refactor 요점 (2026-04-21):
//   - 구 구현은 PDF dispatch 시에 outer withLock 을 최대 4.5분 보유하는 경로가 있었다
//     (대용량 PDF 의 poppler 동기 extract). 신 구현은 PDF disk write 까지 (수 초) 에서
//     outer 를 release 하고, handleIngestPdf 로 하여금 스스로 withLock 을 재취득하게 한다.
//   - 이 변경으로 `skipLock` injection 이 불필요해졌기 때문에 API 자체를 삭제.
//   - race window 의 실해는 없음: gieok_delete 는 wiki/ 이하만 대상 / sha256 멱등으로 중복
//     ingest 도 safe / auto-ingest.sh 와의 경합은 신규 리스크가 아님 (기존 semantic).
//
// 보안 요점:
//   - 외부에서 URL validation (validateUrl)을 마치고 나서 lock 취득
//   - PDF body 상한 (GIEOK_URL_MAX_PDF_BYTES, 기본 50MB)은 positive-int clamp로 0/부정값을 거른다
//   - PDF 기록 대상은 assertInsideRawSourcesSubdir로 raw-sources/<subdir>/ 경계로 강제
//   - urlToFilename + 0o600 atomic write (tmp + rename)
//   - subdir sanitize는 SAFE_PATH_RE (vault-path.mjs) 호환의 문자 집합으로 좁힌다 (silent
//     mangling은 금지 — 부정값은 MED-1에서 reject)
//   - 에러 문자열에 attacker-controlled URL / 내부 IP / credentials를 싣지 않는다
//     (HIGH-2: prompt-injection / SSRF info leak 대책). code-only로 MCP 경계를 넘긴다.

import { mkdir, open, rename, unlink } from 'node:fs/promises';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { withLock } from '../lib/lock.mjs';
import { checkRobots, RobotsError } from '../lib/robots-check.mjs';
import { envPositiveInt } from '../lib/env-helpers.mjs';
import { extractAndSaveUrl } from '../lib/url-extract.mjs';
import { fetchUrl, FetchError } from '../lib/url-fetch.mjs';
import { urlToFilename } from '../lib/url-filename.mjs';
import { UrlSecurityError, validateUrl } from '../lib/url-security.mjs';
import { assertInsideRawSourcesSubdir } from '../lib/vault-path.mjs';
import { handleIngestPdf } from './ingest-pdf.mjs';
// 2026-04-20 v0.3.4: MCP progress heartbeat (client 60s timeout 회피).
import { startHeartbeat } from '../lib/progress-heartbeat.mjs';

const LOCK_TTL_MS = 1_800_000; // 30분 (auto-ingest.sh와 정합)
const LOCK_ACQUIRE_TIMEOUT_MS = 60_000;
const DEFAULT_PDF_BYTES_FALLBACK = 50_000_000;
const DEFAULT_REFRESH_DAYS_FALLBACK = 30;

// HIGH-1 fix (2026-04-19): GIEOK_URL_ALLOW_LOOPBACK=1이 production으로 leak된
// 경우의 조기 경고. MCP child 경유 (GIEOK_MCP_CHILD=1) 또는 NODE_ENV=test에서는 억제.
// MED-d1 fix (2026-04-20): GIEOK_URL_IGNORE_ROBOTS에도 동등한 WARN을 추가
//   (기존 구현에서는 silent였기에 production leak을 알아차리지 못했음).
// MED-d3 fix (2026-04-20): stderr는 MCP stdio나 cron 로그에 묻히기 쉬우므로,
//   감지 시 `$VAULT/.gieok-alerts/<flag>.flag`에 timestamp 파일을 남기고,
//   auto-lint.sh의 자가 진단 / 스모크 절차가 이를 포착할 수 있게 한다.
function warnAndFlag(envVar, message) {
  if (process.env.GIEOK_MCP_CHILD === '1' || process.env.NODE_ENV === 'test') return;
  process.stderr.write(`[gieok-mcp] WARNING: ${message}\n`);
  // best-effort flag file. OBSIDIAN_VAULT 미설정이나 write 실패는 silent pass
  // (기동 경로에서 실패해도 MCP 본체는 동작한다는 전제를 깨지 않는다).
  try {
    const vault = process.env.OBSIDIAN_VAULT;
    if (!vault) return;
    const dir = join(vault, '.gieok-alerts');
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const flagPath = join(dir, `${envVar.toLowerCase()}.flag`);
    writeFileSync(flagPath, `${new Date().toISOString()}\n`, { mode: 0o600 });
  } catch {
    /* best-effort */
  }
}

if (process.env.GIEOK_URL_ALLOW_LOOPBACK === '1') {
  warnAndFlag(
    'GIEOK_URL_ALLOW_LOOPBACK',
    'GIEOK_URL_ALLOW_LOOPBACK=1 detected outside test/MCP-child context — SSRF IP-range checks are bypassed.',
  );
}
if (process.env.GIEOK_URL_IGNORE_ROBOTS === '1') {
  warnAndFlag(
    'GIEOK_URL_IGNORE_ROBOTS',
    'GIEOK_URL_IGNORE_ROBOTS=1 detected outside test/MCP-child context — robots.txt is ignored.',
  );
}

// env footgun guard는 ../lib/env-helpers.mjs의 envPositiveInt를 사용.
// Number("0") === 0 / NaN / 음수는 폴백 (0을 "상한 없음"으로 해석하는 fail-open을 방지).

function getMaxPdfBytes() {
  return envPositiveInt('GIEOK_URL_MAX_PDF_BYTES', DEFAULT_PDF_BYTES_FALLBACK);
}

function getDefaultRefreshDays() {
  // refresh_days는 'never'를 문자열로 허용하기 위해 독자적으로 처리한다.
  const raw = process.env.GIEOK_URL_REFRESH_DAYS;
  if (raw === undefined || raw === '') return DEFAULT_REFRESH_DAYS_FALLBACK;
  if (raw === 'never') return 'never';
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return DEFAULT_REFRESH_DAYS_FALLBACK;
  return Math.floor(n);
}

export const INGEST_URL_TOOL_DEF = {
  name: 'gieok_ingest_url',
  title: 'Fetch a URL and ingest into GIEOK Wiki',
  description:
    'Fetch an HTTP/HTTPS URL, extract the article body (Mozilla Readability; LLM fallback for hard layouts), '
    + 'save the Markdown under raw-sources/<subdir>/fetched/, download inline images to '
    + 'raw-sources/<subdir>/fetched/media/, and let the next auto-ingest cycle produce a wiki summary. '
    + 'If the URL serves a PDF (Content-Type: application/pdf or URL ending in .pdf), the tool '
    + 'dispatches to gieok_ingest_pdf automatically — short PDFs return status: dispatched_to_pdf '
    + 'synchronously, longer PDFs return status: dispatched_to_pdf_queued and produce summaries in '
    + 'the background (poll pdf_result.expected_summaries under wiki/summaries/). '
    + 'Use when the user asks to "read this URL", "save this article", or pastes a link to remember.',
  inputShape: {
    url: z.string().min(1).max(2048),
    subdir: z.string().min(1).max(64).optional(),
    title: z.string().max(200).optional(),
    source_type: z.string().max(64).optional(),
    tags: z.array(z.string().min(1).max(32)).max(16).optional(),
    refresh_days: z.union([z.number().int().min(1).max(3650), z.literal('never')]).optional(),
    max_turns: z.number().int().min(1).max(120).optional(),
  },
};

/**
 * @param {string} vault
 * @param {{url: string, subdir?: string, title?: string, source_type?: string, tags?: string[], refresh_days?: number|'never', max_turns?: number}} args
 * @param {{claudeBin?: string, robotsUrlOverride?: string, sendProgress?: Function}} [injections]
 *
 * 2026-04-21 v0.4.0 Tier A#3 M-a2/M-a4 refactor:
 * - PDF dispatch 시 outer withLock 보유 시간을 최대 4.5분 → 수 초로 단축하기 위해,
 *   inner() 은 PDF 쓰기까지를 withLock 하에서 수행하고, handleIngestPdf 호출은
 *   outer withLock **release 후** 에 실행하는 구조로 변경.
 * - skipLock injection 은 삭제 (API surface 축소). handleIngestPdf 는 항상 스스로
 *   withLock 을 취득한다 (이 파일이 가진 outer withLock 은 그 시점에 released).
 */
export async function handleIngestUrl(vault, args, injections = {}) {
  validate(args);
  const url = String(args.url);

  // 1. SSRF / scheme / credentials의 조기 reject.
  //    GIEOK_URL_ALLOW_LOOPBACK=1이어도 scheme/creds/null의 최소한은 강제한다 (HIGH-1):
  //    flag가 production으로 leak되어도 file://나 user:pass@... 을 그냥 통과시키지 않는다.
  validateUrlWithLoopbackOption(url);

  // subdir sanitize: SAFE_PATH_RE (vault-path.mjs) 호환. Letter / Number / _ / - 만 허용.
  // MED-1 fix: silent mangling ("my notes" → "mynotes")을 폐지하고, 부정값은 reject.
  // 사용자에게 "subdir가 조용히 바뀌었다"는 사고를 일으키지 않는다.
  const subdirRaw = args.subdir ?? 'articles';
  if (!/^[\p{L}\p{N}_-]+$/u.test(subdirRaw)) {
    throwInvalidParams(
      'subdir must be Unicode letters/digits/_/- only (no spaces or punctuation)',
    );
  }
  const subdir = subdirRaw;

  // v0.3.4: heartbeat을 시작. Desktop의 60s MCP request timeout을 회피하기 위해,
  // 내부 처리 (fetch + extract + LLM summary + PDF dispatch) 동안 15s마다
  // progress notification을 계속 보낸다. progressToken이 없는 client (구 프로토콜
  // 등)에서는 no-op. PDF dispatch로 진행하는 경우, handleIngestPdf 측에서도 동일한
  // injections.sendProgress를 사용하므로 단일 token으로 계속 카운트된다.
  const stopHeartbeat = startHeartbeat(
    injections.sendProgress,
    `gieok_ingest_url: processing ${url.slice(0, 80)}`,
  );

  const inner = async () => {
    // 2. fetch (binary 필수 — body를 PDF로 저장할 가능성이 있다).
    //    maxBytes는 PDF cap과 최소 5MB 중 큰 쪽. HTML은 이보다 훨씬 작으므로 영향 없음.
    const maxPdfBytes = getMaxPdfBytes();
    let fetchResult;
    try {
      fetchResult = await fetchUrl(url, {
        accept: 'text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.5',
        maxBytes: Math.max(maxPdfBytes, 5_000_000),
        binary: true,
      });
    } catch (err) {
      mapFetchErrorAndThrow(err);
    }

    // 3. robots.txt — fetch 후에 평가한다 (storage gating).
    //    HTML 경로에서는 extractAndSaveUrl이 다시 checkRobots를 호출하지만, PDF 경로에서는
    //    extractAndSaveUrl을 경유하지 않으므로, 이 함수 자신이 반드시 평가해야 한다.
    //    비용은 robots.txt의 캐시 없는 re-fetch 1회분 (기껏해야 수 KB)으로 defense-in-depth.
    try {
      await checkRobots(url, { robotsUrlOverride: injections.robotsUrlOverride });
    } catch (err) {
      // HIGH-2: robots 에러 메시지에 URL path를 포함시키지 않는다 (attacker-controlled)
      if (err instanceof RobotsError) throwInvalidRequest(`robots rejected: ${err.code || 'disallow'}`);
      throw err;
    }

    // 4. Content-Type 분기
    //    URL pathname 말미의 확장자는 <pathname>.pdf (대소문자 무시)로 판정한다.
    //    쿼리부에 `.pdf`가 포함되어 있어도 fixture 이름을 넘기는 경우가 많으므로
    //    pathname 한정으로 평가한다 (설계서 §4.7 step 2 "URL path 말미가 .pdf").
    const ct = (fetchResult.contentType || '').toLowerCase();
    let pathnameEndsPdf = false;
    try {
      pathnameEndsPdf = /\.pdf$/i.test(new URL(fetchResult.finalUrl || url).pathname);
    } catch {
      // unreachable — fetchUrl이 성공했다면 finalUrl은 valid일 것이다.
      // 만일 throw된 경우에는 false 그대로 (octet-stream PDF 판정이 false로 떨어질 뿐).
    }
    const isPdf =
      ct.includes('application/pdf')
      || ct.includes('application/x-pdf')
      || ((ct.includes('application/octet-stream') || ct === '') && pathnameEndsPdf);

    if (isPdf) {
      if (fetchResult.truncated) {
        // 50MB cap으로 잘렸다 → 실체는 cap 초과. 기록보다 폐기를 우선.
        throwInvalidRequest('PDF exceeds size cap');
      }
      // PDF의 기본 subdir은 'papers' (기능 2의 PDF 배치 규약과 정합).
      // 사용자가 명시적으로 subdir을 지정한 경우에는 그것을 존중한다.
      const pdfSubdir = (args.subdir == null) ? 'papers' : subdir;
      // outer withLock 하에서 PDF 를 disk 에 atomic write 한다.
      // handleIngestPdf 호출은 outer withLock release **후** 에 수행한다
      // (inner 에서 __pendingPdfDispatch signal 을 반환하여 지시한다).
      const { pdfRelPath } = await writePdfToDisk({
        vault,
        subdir: pdfSubdir,
        url,
        body: fetchResult.body,
      });
      return {
        __pendingPdfDispatch: true,
        vault,
        pdfRelPath,
        url,
      };
    }

    if (!ct.includes('text/html') && !ct.includes('application/xhtml+xml')) {
      // HIGH-2 LOW-5 (note): Content-Type은 server 제어지만 ASCII 제어 문자를
      // 제거하고 100자로 잘라낸 뒤에 노출한다.
      throwInvalidRequest(`unsupported content-type: ${sanitizeForError(ct) || '(none)'}`);
    }

    // 5. HTML → orchestrator에 위임. refresh_days는 호출 인자 > env > default.
    const refreshDays = args.refresh_days ?? getDefaultRefreshDays();
    try {
      const r = await extractAndSaveUrl({
        url,
        vault,
        subdir,
        refreshDays,
        title: args.title,
        sourceType: args.source_type,
        tags: args.tags ?? [],
        robotsUrlOverride: injections.robotsUrlOverride,
        claudeBin: injections.claudeBin,
      });
      return { ...r, url };
    } catch (err) {
      // CRIT-1: late-PDF discovery — extractAndSaveUrl은 **비바이너리**로 fetch하므로
      // err.fetchResult.body는 UTF-8 문자열. PDF 바이트열은 U+FFFD로 바뀌어 망가진다.
      // 반드시 binary:true로 재 fetch한 뒤에 dispatch한다.
      if (err && err.code === 'not_html' && err.pdfCandidate) {
        let refetch;
        try {
          refetch = await fetchUrl(url, {
            accept: 'application/pdf,*/*;q=0.5',
            maxBytes: Math.max(getMaxPdfBytes(), 5_000_000),
            binary: true,
          });
        } catch (refetchErr) {
          mapFetchErrorAndThrow(refetchErr);
        }
        if (refetch.truncated) {
          throwInvalidRequest('PDF exceeds size cap');
        }
        const pdfSubdir = (args.subdir == null) ? 'papers' : subdir;
        // late-PDF 경로에서도 outer withLock 내에서 PDF 를 disk 에 write 하고,
        // handleIngestPdf 호출은 outer withLock release 후에 수행한다 (상동).
        const { pdfRelPath } = await writePdfToDisk({
          vault,
          subdir: pdfSubdir,
          url,
          body: refetch.body,
        });
        return {
          __pendingPdfDispatch: true,
          vault,
          pdfRelPath,
          url,
        };
      }
      // HIGH-2: extractAndSaveUrl 유래의 에러도 raw message를 누설하지 않고 code only로 반환
      if (err && err.code === 'extraction_failed') throwInternal(`extraction failed: ${err.code}`);
      if (err && err.code === 'robots_disallow') throwInvalidRequest(`robots: ${err.code}`);
      throw err;
    }
  };

  try {
    // 2026-04-21 M-a2/M-a4 refactor: outer withLock 은 fetch + (PDF 이면) disk write
    // 까지를 지킨다. inner 가 __pendingPdfDispatch signal 을 반환한 경우에는, withLock
    // release **후** 에 handleIngestPdf 를 호출하여 스스로 withLock 을 취득하게 한다.
    // 이로써 outer lock 의 보유 시간이 4.5분 → 수 초로 단축된다.
    const innerResult = await withLock(vault, inner, {
      ttlMs: LOCK_TTL_MS,
      timeoutMs: LOCK_ACQUIRE_TIMEOUT_MS,
    });

    if (innerResult && innerResult.__pendingPdfDispatch) {
      // outer withLock 은 이미 release 완료 (withLock 의 finally 에서 lockfile unlink 완료).
      // handleIngestPdf 가 스스로 withLock 을 acquire 한다.
      //
      // 2026-04-21 v0.4.0 Tier A#3 post-review GAP-1 fix (red/blue 공통 지적):
      // handleIngestPdf 가 실패한 경우, outer withLock 은 이미 release 되어 있으므로
      // PDF 파일이 raw-sources/ 에 orphan 으로 영속화된다. 구 skipLock 설계에서는
      // 전체가 하나의 try/finally 안에 있었기 때문에 orphan 이 관찰되기 어려웠지만, 신 design
      // 에서는 명시적 cleanup 이 필요.
      //
      // cleanup 분기 판정:
      //   - `lock_timeout`: user retry 의 여지가 있으므로 PDF 를 보유 (다음 호출에서 처리됨)
      //   - 그 외 (encrypted_or_invalid / extract rc=2,4,5 / claude -p 실패): PDF 가
      //     processable 하지 않음이 판명되었으므로 삭제. best-effort (unlink 실패는
      //     operator 측에서 수동 cleanup 하면 된다)
      let pdfResult;
      try {
        pdfResult = await handleIngestPdf(
          innerResult.vault,
          { path: innerResult.pdfRelPath },
          {
            claudeBin: injections.claudeBin,
            sendProgress: injections.sendProgress,
          },
        );
      } catch (err) {
        if (err?.code !== 'lock_timeout') {
          try {
            await unlink(join(innerResult.vault, innerResult.pdfRelPath));
          } catch {
            /* best-effort: orphan PDF cleanup 실패는 본체 에러를 가리지 않는다 */
          }
        }
        throw err;
      }
      return {
        status: pdfResult.status === 'queued_for_summary'
          ? 'dispatched_to_pdf_queued'
          : 'dispatched_to_pdf',
        url: innerResult.url,
        path: innerResult.pdfRelPath,
        pdf_result: pdfResult,
      };
    }

    return innerResult;
  } finally {
    await stopHeartbeat('gieok_ingest_url: done');
  }
}

// ----- helpers ---------------------------------------------------------------

// HIGH-1: GIEOK_URL_ALLOW_LOOPBACK=1이어도 scheme/creds/null의 최소한은 강제한다.
// flag는 IP-range check (loopback / private / link-local)만을 skip하는 목적이므로,
// 그 외의 입구 방어는 loopback bypass 시에도 남겨둔다.
function validateUrlWithLoopbackOption(url) {
  if (process.env.GIEOK_URL_ALLOW_LOOPBACK === '1') {
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      throwInvalidParams('URL malformed');
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throwInvalidParams('scheme not allowed');
    }
    if (parsed.username || parsed.password) {
      throwInvalidParams('URL credentials not allowed');
    }
    if (url.includes('\0')) throwInvalidParams('URL contains null byte');
    return;
  }
  try {
    validateUrl(url);
  } catch (err) {
    if (err instanceof UrlSecurityError) throwInvalidParams(`URL rejected: ${err.code || 'invalid'}`);
    throw err;
  }
}

// HIGH-2: FetchError.message는 attacker-controlled URL / 내부 IP / credentials를 포함할 수 있음
// (예: "credentials in URL: http://user:pass@..." / "resolved IP is private: foo → 10.0.0.5" /
//     "HTTPS → HTTP downgrade: <attacker URL>"). MCP 경계에서는 code only로 반환한다.
function mapFetchErrorAndThrow(err) {
  if (err instanceof UrlSecurityError) {
    throwInvalidParams(`URL rejected: ${err.code || 'invalid'}`);
  }
  if (err instanceof FetchError) {
    if (
      err.code === 'auth_required'
      || err.code === 'redirect_limit'
      || err.code === 'scheme_downgrade'
      || err.code === 'redirect_invalid'
      || err.code === 'url_credentials'
      || err.code === 'url_scheme'
      || err.code === 'url_loopback'
      || err.code === 'url_private_ip'
      || err.code === 'url_link_local'
      || err.code === 'url_localhost'
      || err.code === 'url_non_standard_ip'
      || err.code === 'dns_private'
    ) {
      throwInvalidRequest(`fetch rejected: ${err.code}`);
    }
    if (err.code === 'not_found') throwNotFound(`fetch failed: ${err.code}`);
    throwFetchFailed(`fetch failed: ${err.code || 'network_error'}`);
  }
  throw err;
}

// LOW-5 (handoff #13): Content-Type은 server 제어의 문자열. stderr / 구조화 응답에
// 싣기 전에 ASCII 제어 문자를 제거하고, 100자로 truncate한다 (UI / log에서 안전).
function sanitizeForError(s) {
  if (typeof s !== 'string') return '';
  const cleaned = s.replace(/[\x00-\x1f\x7f]/g, '');
  return cleaned.length > 100 ? `${cleaned.slice(0, 100)}…` : cleaned;
}

// 2026-04-21 v0.4.0 Tier A#3 M-a2: 구 dispatchToPdf 는 「PDF 를 disk 에 쓴다」 와
// 「handleIngestPdf 를 호출한다」 를 하나로 수행하고 있었다 (outer withLock 을 4.5분 보유하는 원인).
// refactor 후에는 이 헬퍼는 **PDF 를 disk 에 쓸 때까지** (outer withLock 하에서 실행 가능)
// 를 담당하고, handleIngestPdf 호출은 handleIngestUrl 측에서 outer withLock **release 후**
// 에 수행한다.
async function writePdfToDisk({ vault, subdir, url, body }) {
  if (!body) throwInternal('PDF body missing for dispatch');
  // urlToFilename은 <host>-<slug>.md을 반환하므로 확장자만 교체한다.
  const name = urlToFilename(url).replace(/\.md$/, '.pdf');
  const pdfDir = join(vault, 'raw-sources', subdir);
  await mkdir(pdfDir, { recursive: true, mode: 0o700 });

  // defense-in-depth: urlToFilename은 sanitizer를 가지고 있지만, 여기서도 raw-sources/<subdir>/
  // 하위로 해결됨을 realpath 기반으로 재확인한다.
  const absPath = await assertInsideRawSourcesSubdir(vault, subdir, name);

  // atomic write — tmp는 동일 디렉터리에서 생성 (rename의 동일 FS 보장).
  const tmp = `${absPath}.tmp.${process.pid}.${Date.now()}`;
  const fh = await open(tmp, 'wx', 0o600);
  try {
    await fh.writeFile(body);
  } finally {
    await fh.close();
  }
  await rename(tmp, absPath);

  return {
    pdfRelPath: `raw-sources/${subdir}/${name}`,
  };
}

// MED-3: validate()는 test 등에서 Zod를 bypass하고 직접 호출되는 경로용. Zod schema의
// 제약 (max length / array size / int range)을 runtime에도 복제하여 silent overrun을 방지한다.
function validate(args) {
  if (!args || typeof args !== 'object') throwInvalidParams('args must be an object');
  if (typeof args.url !== 'string' || !args.url.trim()) throwInvalidParams('url required');
  if (args.url.includes('\0')) throwInvalidParams('url contains null byte');
  if (args.url.length > 2048) throwInvalidParams('url too long (max 2048)');
  if (args.subdir != null) {
    if (typeof args.subdir !== 'string') throwInvalidParams('subdir must be a string');
    if (args.subdir.includes('\0')) throwInvalidParams('subdir contains null byte');
    if (args.subdir.length < 1 || args.subdir.length > 64) {
      throwInvalidParams('subdir length must be 1..64');
    }
  }
  if (args.title != null) {
    if (typeof args.title !== 'string') throwInvalidParams('title must be a string');
    if (args.title.length > 200) throwInvalidParams('title too long (max 200)');
  }
  if (args.source_type != null) {
    if (typeof args.source_type !== 'string') {
      throwInvalidParams('source_type must be a string');
    }
    if (args.source_type.length > 64) throwInvalidParams('source_type too long (max 64)');
  }
  if (args.tags != null) {
    if (!Array.isArray(args.tags)) throwInvalidParams('tags must be an array');
    if (args.tags.length > 16) throwInvalidParams('tags must be at most 16 entries');
    for (const t of args.tags) {
      if (typeof t !== 'string') throwInvalidParams('tags must be strings');
      if (t.length < 1 || t.length > 32) throwInvalidParams('tag length must be 1..32');
    }
  }
  if (args.refresh_days != null) {
    const ok =
      (typeof args.refresh_days === 'number'
        && Number.isInteger(args.refresh_days)
        && args.refresh_days >= 1
        && args.refresh_days <= 3650)
      || args.refresh_days === 'never';
    if (!ok) throwInvalidParams('refresh_days must be integer 1..3650 or "never"');
  }
  if (args.max_turns != null) {
    const ok =
      typeof args.max_turns === 'number'
      && Number.isInteger(args.max_turns)
      && args.max_turns >= 1
      && args.max_turns <= 120;
    if (!ok) throwInvalidParams('max_turns must be integer 1..120');
  }
}

function throwInvalidParams(msg) {
  const e = new Error(msg);
  e.code = 'invalid_params';
  throw e;
}
function throwInvalidRequest(msg) {
  const e = new Error(msg);
  e.code = 'invalid_request';
  throw e;
}
function throwNotFound(msg) {
  const e = new Error(msg);
  e.code = 'not_found';
  throw e;
}
function throwFetchFailed(msg) {
  const e = new Error(msg);
  e.code = 'fetch_failed';
  throw e;
}
function throwInternal(msg) {
  const e = new Error(msg);
  e.code = 'internal_error';
  throw e;
}
