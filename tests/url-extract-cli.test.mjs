// tests/url-extract-cli.test.mjs — url-extract-cli.mjs의 spawn smoke 테스트
//
// CLI 계층은 shell wrapper (extract-url.sh)와 MCP tool (Phase 7)에서 호출된다.
// 여기서는 최소한의 계약 (exit code / stdout JSON / stderr message)을 검증한다.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFixtureServer } from './helpers/fixture-server.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CLI = join(__dirname, '..', 'mcp', 'lib', 'url-extract-cli.mjs');

function runCli(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn('node', [CLI, ...args], {
      env: { ...process.env, ...env },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (b) => { stdout += b.toString(); });
    child.stderr.on('data', (b) => { stderr += b.toString(); });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

describe('url-extract-cli', () => {
  let server, workspace, vault;
  before(async () => {
    server = await startFixtureServer();
    workspace = await mkdtemp(join(tmpdir(), 'gieok-uec-'));
    vault = join(workspace, 'vault');
    await mkdir(join(vault, 'raw-sources', 'articles', 'fetched'), { recursive: true });
    await mkdir(join(vault, '.cache', 'html'), { recursive: true });
  });
  after(async () => {
    await server.close();
    await rm(workspace, { recursive: true, force: true });
  });

  test('CLI normal URL → exit 0 + JSON on stdout', async () => {
    const r = await runCli(
      [
        '--url', `${server.url}/article-normal.html`,
        '--vault', vault,
        '--subdir', 'articles',
        '--robots-override', `${server.url}/robots.txt?variant=allow`,
      ],
      { GIEOK_URL_ALLOW_LOOPBACK: '1' },
    );
    assert.equal(r.code, 0, `stderr=${r.stderr}`);
    const json = JSON.parse(r.stdout);
    assert.ok(json.status);
    assert.ok(json.source_sha256);
    assert.match(json.path, /raw-sources\/articles\/fetched\//);
  });

  test('CLI missing --url → exit 2 + stderr', async () => {
    const r = await runCli(['--vault', vault]);
    assert.equal(r.code, 2);
    assert.match(r.stderr, /--url required/i);
  });

  test('CLI missing --vault → exit 2 + stderr', async () => {
    const r = await runCli(['--url', 'https://example.com/']);
    assert.equal(r.code, 2);
    assert.match(r.stderr, /--vault required/i);
  });

  test('CLI robots Disallow → exit 3', async () => {
    const r = await runCli(
      [
        '--url', `${server.url}/article-normal.html`,
        '--vault', vault,
        '--subdir', 'articles',
        '--robots-override', `${server.url}/robots.txt?variant=disallow`,
      ],
      { GIEOK_URL_ALLOW_LOOPBACK: '1' },
    );
    assert.equal(r.code, 3, `stderr=${r.stderr}`);
    assert.match(r.stderr, /robots_disallow/);
  });

  test('CLI fetch failure (non-http scheme in validated mode) → exit 4', async () => {
    const r = await runCli(
      [
        '--url', 'file:///etc/passwd',
        '--vault', vault,
        '--subdir', 'articles',
      ],
      {}, // intentionally no GIEOK_URL_ALLOW_LOOPBACK, no GIEOK_URL_IGNORE_ROBOTS
    );
    // robots check will fail first (file:// scheme rejected by validateUrl).
    // The fetch error propagates as code=url_scheme or similar → exit 4.
    assert.equal(r.code, 4, `stdout=${r.stdout} stderr=${r.stderr}`);
  });

  test('CLI security-code error message is scrubbed (red M-2)', async () => {
    // red M-2 fix (2026-04-20): FetchError의 raw message에 해결된 내부 IP나
    // attacker-controlled hostname이 그대로 embed된 상태로 cron log에
    // leak되는 경로를 차단. security code (url_scheme / dns_private / ...)에서는
    // err.message를 내지 않고 "blocked by security policy"만 stderr에 출력.
    const r = await runCli(
      [
        '--url', 'file:///etc/passwd',
        '--vault', vault,
        '--subdir', 'articles',
      ],
    );
    assert.equal(r.code, 4);
    assert.match(r.stderr, /blocked by security policy/, 'scrubbed generic message expected');
    // 내부 경로나 URL 문자열이 stderr에 leak되지 않음
    assert.doesNotMatch(r.stderr, /\/etc\/passwd/, 'attacker-controlled URL path must not leak');
    assert.doesNotMatch(r.stderr, /file:\/\//, 'raw scheme must not leak');
    // code는 출력 (operator 측 debug 정보로 필요)
    assert.match(r.stderr, /\((url_scheme|url_parse)\)/, 'code is still surfaced for ops visibility');
  });

  test('CLI tags flag parses comma-separated list', async () => {
    // 다른 subdir로 fresh 쓰기 (orchestrator의 idempotency로 이전 file이 skip을
    // 반환해버리므로 테스트 단위로 isolate한다).
    const r = await runCli(
      [
        '--url', `${server.url}/article-normal.html`,
        '--vault', vault,
        '--subdir', 'tags-test',
        '--robots-override', `${server.url}/robots.txt?variant=allow`,
        '--tags', 'foo, bar ,baz',
      ],
      { GIEOK_URL_ALLOW_LOOPBACK: '1' },
    );
    assert.equal(r.code, 0, `stderr=${r.stderr}`);
    const json = JSON.parse(r.stdout);
    assert.ok(json.status);
    const { readFile } = await import('node:fs/promises');
    const content = await readFile(join(vault, json.path), 'utf8');
    assert.match(content, /tags: \["foo", "bar", "baz"\]/);
  });

  test('CLI --refresh-days=never → passed through', async () => {
    const r = await runCli(
      [
        '--url', `${server.url}/article-normal.html`,
        '--vault', vault,
        '--subdir', 'never-test',
        '--robots-override', `${server.url}/robots.txt?variant=allow`,
        '--refresh-days', 'never',
      ],
      { GIEOK_URL_ALLOW_LOOPBACK: '1' },
    );
    assert.equal(r.code, 0, `stderr=${r.stderr}`);
    const json = JSON.parse(r.stdout);
    assert.ok(json.status);
    const { readFile } = await import('node:fs/promises');
    const content = await readFile(join(vault, json.path), 'utf8');
    assert.match(content, /refresh_days: "never"/);
  });
});
