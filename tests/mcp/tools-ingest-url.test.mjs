// tools-ingest-url.test.mjs — gieok_ingest_url MCP tool (기능 2.2) 단위/통합 테스트.
//
// MCP31   정상 URL → fetched_and_summarized_pending
// MCP32   SSRF: localhost reject (GIEOK_URL_ALLOW_LOOPBACK=0 강제)
// MCP32b  HIGH-1: GIEOK_URL_ALLOW_LOOPBACK=1 이어도 file://은 reject
// MCP32c  HIGH-1: GIEOK_URL_ALLOW_LOOPBACK=1 이어도 user:pass@는 reject
// MCP33   멱등 재실행 → skipped
// MCP34   robots Disallow → invalid_request
// MCP35   lockfile 경합 → 200ms 후에도 pending (acquire 중) — try/finally로 cleanup (HIGH-3)
// MCP36   child env allowlist (GH_TOKEN 누출 없음, GIEOK_NO_LOG / GIEOK_MCP_CHILD은 전파)
// MCP37   default subdir = articles
// MCP38   title 인자 → frontmatter
// MCP39   tags 전파 + masking (MED-4: tag 값도 applyMasks를 거침)
// MCP40   refresh_days 인자 → frontmatter
// MCP41   HTML content-type → 일반 URL 플로우 (PDF dispatch 안 함)
// MCP42   application/pdf → handleIngestPdf로 dispatch
// MCP43   octet-stream + URL 끝 .pdf → dispatch
// MCP44   PDF body > 50MB → invalid_request
// MCP45   dispatch에서는 skipLock=true로 내측 withLock을 거치지 않고 즉시 진행
// MCP46   CRIT-1: late-PDF discovery로 binary 재 fetch하여 PDF magic bytes가 유지됨
// MCP46b  v0.3.5 Option B: 긴 PDF dispatch → status: dispatched_to_pdf_queued
// MCP47   HIGH-2: fetch 에러 메시지에 credentials / 내부 IP / raw URL을 포함하지 않음
// MCP48   MED-1: subdir에 공백 등 부정 문자 → silent mangle이 아니라 invalid_params로 reject
//
// 외부 의존:
//   - fixture-server.mjs가 /article-normal.html, /article-sparse.html, /robots.txt,
//     /pdf?name=, /huge-pdf를 제공.
//   - PDF dispatch는 handleIngestPdf 경유로 extract-pdf.sh를 spawn하므로 poppler가 필요.
//     미설치 환경에서는 PDF dispatch 스위트를 skip한다.
//   - claude CLI는 stub으로 교체 (stubBin). LLM fallback (llm-fallback.mjs)도 같은 stub을 호출.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, mkdir, writeFile, readFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFixtureServer } from '../helpers/fixture-server.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(__dirname, '..', '..', 'mcp');

const { handleIngestUrl } = await import(join(MCP_DIR, 'tools', 'ingest-url.mjs'));

// poppler가 없으면 PDF dispatch 서브 스위트를 skip (handleIngestPdf가 extract-pdf.sh
// 를 spawn하므로 pdfinfo / pdftotext가 필요).
const popplerCheck = spawnSync(
  'sh',
  ['-c', 'command -v pdfinfo >/dev/null 2>&1 && command -v pdftotext >/dev/null 2>&1'],
  { stdio: 'ignore' },
);
const HAS_POPPLER = popplerCheck.status === 0;

let server;
let workspace;
let stubBin;
let stubLog;

before(async () => {
  process.env.GIEOK_URL_ALLOW_LOOPBACK = '1';
  server = await startFixtureServer();
  workspace = await mkdtemp(join(tmpdir(), 'gieok-iu-'));
  stubBin = join(workspace, 'claude-stub.sh');
  stubLog = join(workspace, 'claude-stub.log');
  // stub claude:
  //   - argv와 GIEOK_* / OBSIDIAN_VAULT / GH_TOKEN / AWS_* / ANTHROPIC_을 log에 dump
  //   - LLM fallback (llm-fallback.mjs)가 GIEOK_LLM_FB_OUT을 넘기면
  //     해당 경로에 최소한의 Markdown을 기록하고 exit 0 (실 LLM의 대체)
  const script = [
    '#!/usr/bin/env bash',
    '{',
    '  echo "=== invocation ==="',
    '  echo "ARGV: $*"',
    "  env | grep -E '^(GIEOK_|OBSIDIAN_VAULT=|ANTHROPIC_|GH_TOKEN=|AWS_)' | sort",
    '  echo "--- end env ---"',
    `} >> "${stubLog}"`,
    'if [[ -n "${GIEOK_LLM_FB_OUT:-}" ]]; then',
    '  {',
    '    echo "# Fallback Stub"',
    '    echo "Body from fallback."',
    '  } > "$GIEOK_LLM_FB_OUT"',
    'fi',
    'exit 0',
    '',
  ].join('\n');
  await writeFile(stubBin, script, { mode: 0o755 });
  await chmod(stubBin, 0o755);
});

after(async () => {
  delete process.env.GIEOK_URL_ALLOW_LOOPBACK;
  if (server) await server.close();
  if (workspace) await rm(workspace, { recursive: true, force: true });
});

async function makeVault(name) {
  const v = join(workspace, name);
  await mkdir(join(v, 'raw-sources', 'articles', 'fetched'), { recursive: true });
  await mkdir(join(v, 'raw-sources', 'papers'), { recursive: true });
  await mkdir(join(v, 'wiki', 'summaries'), { recursive: true });
  await mkdir(join(v, '.cache', 'extracted'), { recursive: true });
  await mkdir(join(v, '.cache', 'html'), { recursive: true });
  return v;
}

describe('gieok_ingest_url', () => {
  test('MCP31 normal URL → fetched_and_summarized_pending', async () => {
    const v = await makeVault('mcp31');
    const r = await handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html` },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    assert.ok(
      ['fetched_and_summarized', 'fetched_and_summarized_pending', 'fetched_only'].includes(r.status),
      `unexpected status: ${r.status}`,
    );
    assert.ok(r.path.startsWith('raw-sources/articles/fetched/'));
  });

  test('MCP32 SSRF: localhost rejected when GIEOK_URL_ALLOW_LOOPBACK=0', async () => {
    process.env.GIEOK_URL_ALLOW_LOOPBACK = '0';
    try {
      const v = await makeVault('mcp32');
      await assert.rejects(
        () => handleIngestUrl(v, { url: 'http://localhost/foo' }, { claudeBin: stubBin }),
        (e) => e.code === 'invalid_params',
      );
    } finally {
      process.env.GIEOK_URL_ALLOW_LOOPBACK = '1';
    }
  });

  test('MCP32b HIGH-1: loopback flag still rejects file:// scheme', async () => {
    // GIEOK_URL_ALLOW_LOOPBACK=1이 production에 leak되어도 scheme allowlist
    // (http/https only)는 강제됨. SSRF IP-range만 skip되는 설계.
    const v = await makeVault('mcp32b');
    await assert.rejects(
      () => handleIngestUrl(v, { url: 'file:///etc/passwd' }, { claudeBin: stubBin }),
      (e) => e.code === 'invalid_params',
    );
  });

  test('MCP32c HIGH-1: loopback flag still rejects URL credentials', async () => {
    // user:pass@host도 동일하게 loopback bypass 시에도 reject되어야 함
    // (raw credential이 log / error / network 경로에 실리지 않도록).
    const v = await makeVault('mcp32c');
    await assert.rejects(
      () => handleIngestUrl(
        v,
        { url: 'http://user:pass@127.0.0.1:8080/foo' },
        { claudeBin: stubBin },
      ),
      (e) => e.code === 'invalid_params',
    );
  });

  test('MCP33 idempotent second call → skipped', async () => {
    const v = await makeVault('mcp33');
    await handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html` },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    const r2 = await handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html` },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    assert.match(r2.status, /skipped/, `expected skipped status, got: ${r2.status}`);
  });

  test('MCP34 robots Disallow → invalid_request', async () => {
    const v = await makeVault('mcp34');
    await assert.rejects(
      () => handleIngestUrl(
        v,
        { url: `${server.url}/article-normal.html` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=disallow` },
      ),
      (e) => e.code === 'invalid_request',
    );
  });

  test('MCP35 lockfile held externally → still pending after 200ms', async () => {
    // HIGH-3 fix: assert.equal이 실패해도 lockfile / setTimeout / dangling promise가
    // 남지 않도록 try/finally + clearTimeout으로 확실히 cleanup한다.
    // 구 구현은 assert 실패 시 lockfile이 잔존하여 후속 테스트의 workspace가 손상될
    // 가능성이 있었다.
    const v = await makeVault('mcp35');
    // 다른 PID 스타일의 lockfile을 둔다 (TTL 내 취급)
    await writeFile(join(v, '.gieok-mcp.lock'), '99999\n');
    const p = handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html` },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    let tickHandle;
    const tick = new Promise((r) => { tickHandle = setTimeout(() => r('pending'), 200); });
    try {
      const res = await Promise.race([p.catch((e) => ({ err: e })), tick]);
      assert.equal(res, 'pending', `expected still pending on lock, got: ${JSON.stringify(res)}`);
    } finally {
      // setTimeout을 확실히 해제 (Promise.race 후 dangling handle 대책)
      clearTimeout(tickHandle);
      // lockfile을 unlink하면 handler가 acquire하여 진행 → 완료시킨 뒤 resolve
      await rm(join(v, '.gieok-mcp.lock'), { force: true });
      await p.catch(() => {});
    }
  });

  test('MCP36 child env allowlist (no GH_TOKEN leak, GIEOK_NO_LOG / MCP_CHILD propagated)', async () => {
    await writeFile(stubLog, '');
    const prevGh = process.env.GH_TOKEN;
    process.env.GH_TOKEN = 'ghp_SHOULD_NOT_LEAK';
    try {
      const v = await makeVault('mcp36');
      // sparse HTML → Readability needsFallback → llm-fallback.mjs가 stub claude를 spawn
      await handleIngestUrl(
        v,
        { url: `${server.url}/article-sparse.html` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
    } finally {
      if (prevGh === undefined) delete process.env.GH_TOKEN;
      else process.env.GH_TOKEN = prevGh;
    }
    const log = await readFile(stubLog, 'utf8');
    assert.doesNotMatch(log, /SHOULD_NOT_LEAK/, 'GH_TOKEN must not propagate to LLM fallback child');
    assert.match(log, /GIEOK_NO_LOG=1/, 'GIEOK_NO_LOG=1 propagated');
    assert.match(log, /GIEOK_MCP_CHILD=1/, 'GIEOK_MCP_CHILD=1 propagated');
  });

  test('MCP37 default subdir = articles', async () => {
    const v = await makeVault('mcp37');
    const r = await handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html` },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    assert.match(r.path, /raw-sources\/articles\/fetched\//);
  });

  test('MCP38 title arg overrides frontmatter title', async () => {
    const v = await makeVault('mcp38');
    const r = await handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html`, title: 'Custom Title' },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    const content = await readFile(join(v, r.path), 'utf8');
    assert.match(content, /title: "Custom Title"/);
  });

  test('MCP39 tags propagate to frontmatter and tag values are masked', async () => {
    // MED-4 fix (code-quality 2026-04-19): tag 값도 applyMasks를 거침.
    // 구 구현에서는 url-extract.mjs#buildFrontmatterObject가 tags를 그대로 넘겨
    // frontmatter에 GitHub PAT 등의 secret 문자열이 누출 → vault의 git push로
    // commit history에 영구 잔존하는 결함이 있었다.
    const v = await makeVault('mcp39');
    // MED-3 fix로 tag는 32자 이하로 validate됨. GitHub PAT mask rule
    // (`ghp_[A-Za-z0-9]{20,}`)을 만족하는 최단 sentinel = `ghp_` + 20자 = 24자.
    // SHOULD_BE_MASKED 문자열 (16 chars)을 20자 alnum에 포함시켜 leak 감지 가능하게 함.
    // 32 chars total: 'ghp_' (4) + 'SHOULDBEMASKED' (14) + 'xxxxxxxxxxxxxx' (14) = 32
    const sentinel = 'ghp_SHOULDBEMASKEDxxxxxxxxxxxxxx';
    assert.ok(sentinel.length <= 32, 'sentinel must fit in tag length limit');
    assert.match(sentinel, /^ghp_[A-Za-z0-9]{20,}$/, 'sentinel must match ghp_ mask rule');
    const r = await handleIngestUrl(
      v,
      {
        url: `${server.url}/article-normal.html`,
        tags: ['t1', sentinel],
      },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    const content = await readFile(join(v, r.path), 'utf8');
    assert.match(content, /tags: \[/, 'tags array present in frontmatter');
    assert.match(content, /"t1"/, 't1 propagated');
    // 원 값 (sentinel)은 frontmatter에서도 본문에서도 누출되면 안 됨
    assert.doesNotMatch(content, /SHOULDBEMASKED/, 'tag secret must be masked');
    // 대신 mask placeholder가 들어 있는지 확인 (applyMasks는 ghp_ → ghp_***)
    assert.match(content, /"ghp_\*\*\*"/, 'mask placeholder applied to tag');
  });

  test('MCP39b og_image / published_time meta secrets are masked (red M-1)', async () => {
    // red M-1 fix (2026-04-20): <meta property="og:image">와
    // <meta property="article:published_time">의 raw 문자열이 attacker-controlled.
    // 구 구현에서는 url-extract.mjs#buildFrontmatterObject가 setRaw였으므로
    // `og_image: "https://.../?ghp_..."`와 같은 secret-bearing meta가 frontmatter에
    // 그대로 남아, git push로 commit history에 영속화되는 결함이 있었다.
    const v = await makeVault('mcp39b');
    const r = await handleIngestUrl(
      v,
      { url: `${server.url}/article-meta-secrets.html` },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    const content = await readFile(join(v, r.path), 'utf8');
    // og:image와 published_time의 secret sentinel은 frontmatter에서 사라짐
    assert.doesNotMatch(content, /METAPUBTIMESECRET/, 'published_time sentinel must be masked');
    assert.doesNotMatch(content, /METAOGIMGSECRET/, 'og_image sentinel must be masked');
    // mask placeholder가 들어 있는 것도 확인 (applyMasks는 ghp_ → ghp_***)
    assert.match(content, /ghp_\*\*\*/, 'mask placeholder applied to meta frontmatter');
  });

  test('MCP40 refresh_days arg overrides global default', async () => {
    const v = await makeVault('mcp40');
    const r = await handleIngestUrl(
      v,
      { url: `${server.url}/article-normal.html`, refresh_days: 7 },
      { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
    );
    const content = await readFile(join(v, r.path), 'utf8');
    assert.match(content, /refresh_days: 7/);
  });

  describe('PDF dispatch (§4.7)', { skip: !HAS_POPPLER ? 'poppler not installed' : false }, () => {
    test('MCP41 HTML content-type → no PDF dispatch', async () => {
      const v = await makeVault('mcp41');
      const r = await handleIngestUrl(
        v,
        { url: `${server.url}/article-normal.html` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
      assert.notEqual(r.status, 'dispatched_to_pdf', `unexpected dispatch: ${r.status}`);
    });

    test('MCP42 application/pdf → dispatch to handleIngestPdf', async () => {
      const v = await makeVault('mcp42');
      const r = await handleIngestUrl(
        v,
        { url: `${server.url}/pdf?name=sample-8p.pdf` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
      // 8p PDF = 1 chunk이므로 size-gate 하한 쪽 (sync 계속)
      assert.equal(r.status, 'dispatched_to_pdf');
      assert.ok(
        r.path.startsWith('raw-sources/papers/'),
        `expected raw-sources/papers/ prefix, got: ${r.path}`,
      );
      assert.ok(r.pdf_result, 'pdf_result wrapper present');
      assert.equal(r.pdf_result.status, 'extracted_and_summarized',
        'short PDF should be summarized synchronously');
    });

    test('MCP42b v0.3.5: long PDF (42p = 3 chunks) → dispatched_to_pdf_queued', async () => {
      // handleIngestPdf가 `queued_for_summary`를 반환하는 분기가 URL 경로에서도
      // `dispatched_to_pdf_queued`로 올바르게 전파될 것.
      const v = await makeVault('mcp42b');
      const r = await handleIngestUrl(
        v,
        { url: `${server.url}/pdf?name=sample-42p.pdf` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
      assert.equal(r.status, 'dispatched_to_pdf_queued',
        `long PDF should surface queued status, got: ${JSON.stringify(r).slice(0, 300)}`);
      assert.ok(r.path.startsWith('raw-sources/papers/'), `path: ${r.path}`);
      assert.ok(r.pdf_result, 'pdf_result wrapper present');
      assert.equal(r.pdf_result.status, 'queued_for_summary',
        'inner pdf_result should mirror the queued status');
      assert.ok(
        Array.isArray(r.pdf_result.expected_summaries)
          && r.pdf_result.expected_summaries.length >= 2,
        'expected_summaries must guide client to poll wiki/summaries/',
      );
      assert.equal(typeof r.pdf_result.detached_pid, 'number', 'detached_pid surfaced');
    });

    test('MCP43 octet-stream + URL .pdf → dispatch', async () => {
      const v = await makeVault('mcp43');
      // /pdf-file/<name>.pdf로 하면 pathname 끝이 `.pdf`가 되어,
      // octet-stream Content-Type이어도 PDF로 dispatch된다.
      const r = await handleIngestUrl(
        v,
        {
          url: `${server.url}/pdf-file/sample-8p.pdf?ct=${encodeURIComponent('application/octet-stream')}`,
        },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
      assert.equal(r.status, 'dispatched_to_pdf');
    });

    test('MCP44 PDF body > 50MB → invalid_request', async () => {
      const v = await makeVault('mcp44');
      await assert.rejects(
        () => handleIngestUrl(
          v,
          { url: `${server.url}/huge-pdf` },
          { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
        ),
        (e) => e.code === 'invalid_request',
      );
    });

    test('MCP45 dispatch uses skipLock (no re-entrance deadlock)', async () => {
      // 내측 handleIngestPdf가 skipLock=false면 외측 withLock과 이중 획득으로
      // 60s timeout. skipLock=true가 전달되면 즉시 진행.
      const v = await makeVault('mcp45');
      const r = await handleIngestUrl(
        v,
        { url: `${server.url}/pdf?name=sample-8p.pdf` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
      assert.equal(r.status, 'dispatched_to_pdf');
    });

    test('MCP46 CRIT-1: late-PDF discovery re-fetches with binary mode', async () => {
      // late-PDF discovery 경로:
      //   1회째 fetch (ingest-url 측 binary:true) → text/html 수신
      //   → extractAndSaveUrl에 위임 (refresh skip 등을 위해 비바이너리 재 fetch)
      //   2회째 fetch (extractAndSaveUrl 측, 비바이너리) → application/pdf 수신
      //   → not_html + pdfCandidate로 라우팅
      //
      // 구 구현 (CRIT-1 fix 전)은 err.fetchResult.body (UTF-8 문자열로 decode 완료)를
      // 그대로 PDF로 저장 → PDF 바이트가 U+FFFD로 깨짐.
      // 수정 후는 binary:true로 재 fetch하므로 magic bytes (%PDF-)가 유지됨.
      //
      // /html-then-pdf?name=은 같은 URL에 대해 1회째 HTML / 2회째 이후 PDF를 반환하는
      // fixture-server endpoint. Map<string,count>로 카운트, test 간 workspace가
      // 분리되어 있어도 서버 프로세스 너머로 상태가 공유됨 (본 테스트에서도 고유한
      // name을 넘기면 간섭하지 않음).
      const v = await makeVault('mcp46');
      // counter는 startFixtureServer에서 reset (1회째 = HTML, 2회째 이후 = PDF)
      // 이미 다른 test에서 같은 name을 사용하지 않았는지 혹시 몰라 counter clear.
      server.htmlThenPdfCounts.clear();
      const r = await handleIngestUrl(
        v,
        { url: `${server.url}/html-then-pdf?name=sample-8p.pdf` },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      );
      assert.equal(r.status, 'dispatched_to_pdf');
      assert.ok(r.path.startsWith('raw-sources/papers/'));
      // 저장 파일이 valid PDF (PDF magic bytes %PDF-로 시작) 임을 확인.
      // 구 코드는 UTF-8 깨짐으로 손상 → magic bytes가 일치하지 않음.
      const saved = await readFile(join(v, r.path));
      assert.equal(
        saved.subarray(0, 5).toString('ascii'),
        '%PDF-',
        'saved file must start with %PDF- magic bytes',
      );
      // fixture와 완전 일치하는지도 확인 (UTF-8 경로를 거쳤다면 반드시 차이가 발생)
      const fixture = await readFile(
        join(__dirname, '..', 'fixtures', 'pdf', 'sample-8p.pdf'),
      );
      assert.equal(
        Buffer.compare(saved, fixture),
        0,
        'saved PDF must be byte-identical to the fixture (no UTF-8 corruption)',
      );
    });
  });

  test('MCP47 HIGH-2: fetch error message does not leak credentials in URL', async () => {
    // GIEOK_URL_ALLOW_LOOPBACK=1 (테스트)이어도, url credentials는 HIGH-1 fix로
    // invalid_params가 됨. 여기서 확인하고 싶은 것은, production 경로 (loopback flag
    // 없음)에서 fetchUrl이 credentials를 포함하는 URL을 끌어왔을 때, 상위로 던지는
    // 에러 메시지에 `secret` 문자열이 포함되지 않는 것.
    // FetchError.message는 raw URL을 포함하지만, ingest-url.mjs (HIGH-2 fix)에서 code only로
    // 재작성한 뒤 throw하므로 message에 secret은 실리지 않음.
    process.env.GIEOK_URL_ALLOW_LOOPBACK = '0';
    try {
      const v = await makeVault('mcp47');
      const sentinel = 'TOPSECRET_DO_NOT_LEAK_AAAAA';
      let caught;
      try {
        await handleIngestUrl(
          v,
          { url: `http://user:${sentinel}@example.com/foo` },
          { claudeBin: stubBin },
        );
      } catch (e) {
        caught = e;
      }
      assert.ok(caught, 'expected handleIngestUrl to throw');
      // 에러 code는 invalid_params (URL credentials는 url-security.validateUrl
      // 에서 reject됨)이 바람직하지만, network 경로에 도달하면 invalid_request
      // 여도 가능. 중요한 건 sentinel이 message에 실리지 않는 것.
      assert.doesNotMatch(
        caught.message || '',
        new RegExp(sentinel),
        'sentinel credential must not appear in error message',
      );
    } finally {
      process.env.GIEOK_URL_ALLOW_LOOPBACK = '1';
    }
  });

  test('MCP48 MED-1: subdir with whitespace rejected (no silent mangling)', async () => {
    // 구 구현: subdir.replace(/[^\p{L}\p{N}_-]/gu, '')로 "my notes" → "mynotes"로
    // 소리 없이 변경되는 UX trap. 수정 후는 invalid_params로 reject한다.
    const v = await makeVault('mcp48');
    await assert.rejects(
      () => handleIngestUrl(
        v,
        { url: `${server.url}/article-normal.html`, subdir: 'my notes' },
        { claudeBin: stubBin, robotsUrlOverride: `${server.url}/robots.txt?variant=allow` },
      ),
      (e) => e.code === 'invalid_params',
    );
  });
});
