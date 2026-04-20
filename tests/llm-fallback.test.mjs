import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod, rm, mkdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { llmFallbackExtract } from '../mcp/lib/llm-fallback.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

let workspace, stubBin;
before(async () => {
  workspace = await mkdtemp(join(tmpdir(), 'gieok-llmfb-'));
  stubBin = join(workspace, 'claude-stub.sh');
  // stub writes a known markdown to the target file then exits 0
  await writeFile(stubBin, `#!/usr/bin/env bash
# Stub claude: write a marker file to the CWD-relative path passed via prompt.
# We rely on the handler passing the target path via env GIEOK_LLM_FB_OUT.
echo "# Stub Extracted Title" > "$GIEOK_LLM_FB_OUT"
echo "" >> "$GIEOK_LLM_FB_OUT"
echo "Stub body content derived from HTML." >> "$GIEOK_LLM_FB_OUT"
echo "ARGV: $*" > "$GIEOK_LLM_FB_LOG"
env | sort >> "$GIEOK_LLM_FB_LOG"
exit 0
`);
  await chmod(stubBin, 0o755);
});
after(() => rm(workspace, { recursive: true, force: true }));

describe('llm-fallback', () => {
  test('UE6 stub claude writes markdown and llmFallbackExtract returns it', async () => {
    const out = await llmFallbackExtract({
      html: '<html><body><div>Sparse</div></body></html>',
      url: 'https://example.com/',
      cacheDir: workspace,
      claudeBin: stubBin,
    });
    assert.match(out.markdown, /Stub Extracted Title/);
    assert.equal(out.success, true);
  });

  test('UE7 timeout triggers failure', async () => {
    const slowStub = join(workspace, 'claude-slow.sh');
    await writeFile(slowStub, '#!/usr/bin/env bash\nsleep 60\nexit 0\n');
    await chmod(slowStub, 0o755);
    const out = await llmFallbackExtract({
      html: '<html></html>',
      url: 'https://example.com/',
      cacheDir: workspace,
      claudeBin: slowStub,
      timeoutMs: 200,
    });
    assert.equal(out.success, false);
    assert.match(out.error, /timeout/i);
  });

  test('UE8 --allowedTools pattern + GIEOK_NO_LOG + GIEOK_MCP_CHILD + secrets stripped', async () => {
    const logPath = join(workspace, 'argv-env.log');
    process.env.GIEOK_LLM_FB_LOG = logPath;
    // Set sentinel secrets that should NOT propagate
    process.env.AWS_SECRET_ACCESS_KEY = 'SHOULD_NOT_LEAK_AWS';
    process.env.GITHUB_TOKEN = 'SHOULD_NOT_LEAK_GH';
    try {
      await llmFallbackExtract({
        html: '<html><body><p>x</p></body></html>',
        url: 'https://example.com/',
        cacheDir: workspace,
        claudeBin: stubBin,
      });
    } finally {
      delete process.env.GIEOK_LLM_FB_LOG;
      delete process.env.AWS_SECRET_ACCESS_KEY;
      delete process.env.GITHUB_TOKEN;
    }
    const log = await readFile(logPath, 'utf8');
    assert.match(log, /--allowedTools Write\(/);
    assert.doesNotMatch(log, /--allowedTools[^\n]*Read/);
    assert.doesNotMatch(log, /--allowedTools[^\n]*Bash/);
    assert.match(log, /GIEOK_NO_LOG=1/);
    assert.match(log, /GIEOK_MCP_CHILD=1/);
    // Negative assertions: non-allowlisted secrets must not leak to child env
    assert.doesNotMatch(log, /SHOULD_NOT_LEAK_AWS/);
    assert.doesNotMatch(log, /SHOULD_NOT_LEAK_GH/);
  });

  test('UE9 GIEOK_URL_* security/config env must NOT propagate to child (HIGH-d1)', async () => {
    // 2026-04-20 HIGH-d1 regression test: 구 구현은 `ENV_ALLOW_PREFIXES=['GIEOK_']` 로
    // GIEOK_URL_ALLOW_LOOPBACK 등의 SSRF bypass 플래그를 child 에 propagate 시켰다.
    // child-env.mjs 도입으로 exact-match allowlist 로 전환 완료. 이하의 env 가 child argv log 에
    // 나타나지 않는 것을 확인한다.
    const logPath = join(workspace, 'argv-env-urlsecurity.log');
    process.env.GIEOK_LLM_FB_LOG = logPath;
    process.env.GIEOK_URL_ALLOW_LOOPBACK = '1';
    process.env.GIEOK_URL_IGNORE_ROBOTS = '1';
    process.env.GIEOK_EXTRACT_URL_SCRIPT = '/tmp/evil.sh';
    process.env.GIEOK_ALLOW_EXTRACT_URL_OVERRIDE = '1';
    process.env.GIEOK_URL_MAX_PDF_BYTES = '1';
    process.env.GIEOK_URL_USER_AGENT = 'pwned/1.0';
    try {
      await llmFallbackExtract({
        html: '<html><body><p>x</p></body></html>',
        url: 'https://example.com/',
        cacheDir: workspace,
        claudeBin: stubBin,
      });
    } finally {
      delete process.env.GIEOK_LLM_FB_LOG;
      delete process.env.GIEOK_URL_ALLOW_LOOPBACK;
      delete process.env.GIEOK_URL_IGNORE_ROBOTS;
      delete process.env.GIEOK_EXTRACT_URL_SCRIPT;
      delete process.env.GIEOK_ALLOW_EXTRACT_URL_OVERRIDE;
      delete process.env.GIEOK_URL_MAX_PDF_BYTES;
      delete process.env.GIEOK_URL_USER_AGENT;
    }
    const log = await readFile(logPath, 'utf8');
    // SSRF 의 최종 방어선인 GIEOK_URL_ALLOW_LOOPBACK 이 child 에 누출되지 않을 것
    assert.doesNotMatch(log, /GIEOK_URL_ALLOW_LOOPBACK/, 'GIEOK_URL_ALLOW_LOOPBACK must not leak to child');
    assert.doesNotMatch(log, /GIEOK_URL_IGNORE_ROBOTS/, 'GIEOK_URL_IGNORE_ROBOTS must not leak to child');
    assert.doesNotMatch(log, /GIEOK_EXTRACT_URL_SCRIPT/, 'GIEOK_EXTRACT_URL_SCRIPT must not leak to child');
    assert.doesNotMatch(log, /GIEOK_ALLOW_EXTRACT_URL_OVERRIDE/, 'override flag must not leak to child');
    assert.doesNotMatch(log, /GIEOK_URL_MAX_PDF_BYTES/, 'cap setting must not leak to child');
    assert.doesNotMatch(log, /GIEOK_URL_USER_AGENT/, 'UA override must not leak to child');
    // 내부 통신 플래그는 계속 propagate 됨 (regression 없음)
    assert.match(log, /GIEOK_NO_LOG=1/, 'GIEOK_NO_LOG is still propagated (internal flag)');
    assert.match(log, /GIEOK_MCP_CHILD=1/, 'GIEOK_MCP_CHILD is still propagated (internal flag)');
  });
});
