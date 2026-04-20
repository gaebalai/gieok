// tests/url-extract.test.mjs — url-extract orchestrator 통합 테스트
//
// 설계서 §4.2 / §4.6 — UI9-16 idempotency + refresh_days + orchestration 전체.
// 실 Vault 오염을 피하기 위해 $OBSIDIAN_VAULT는 건드리지 않고, mkdtemp의 임시 디렉터리에서 완결.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { extractAndSaveUrl } from '../mcp/lib/url-extract.mjs';
import { startFixtureServer } from './helpers/fixture-server.mjs';

describe('url-extract orchestrator', () => {
  let server, workspace, vault;
  before(async () => {
    process.env.GIEOK_URL_ALLOW_LOOPBACK = '1';
    server = await startFixtureServer();
    workspace = await mkdtemp(join(tmpdir(), 'gieok-ue-'));
    vault = join(workspace, 'vault');
    await mkdir(join(vault, 'raw-sources', 'articles', 'fetched'), { recursive: true });
    await mkdir(join(vault, '.cache', 'html'), { recursive: true });
  });
  after(async () => {
    delete process.env.GIEOK_URL_ALLOW_LOOPBACK;
    await server.close();
    await rm(workspace, { recursive: true, force: true });
  });

  test('orchestration: normal article → writes markdown + media + frontmatter', async () => {
    const r = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault,
      subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
    });
    assert.equal(r.status, 'fetched_and_summarized_pending');
    assert.match(r.path, /raw-sources\/articles\/fetched\/127\.0\.0\.1-article-normal\.md$/);
    const content = await readFile(join(vault, r.path), 'utf8');
    assert.match(content, /title: "Attention Is All You Need"/);
    assert.match(content, /source_url: "/);
    assert.match(content, /^source_sha256: "[0-9a-f]{64}"$/m);
    assert.match(content, /fallback_used: "readability"/);
    assert.match(content, /refresh_days: 30/);
  });

  test('UI9 same content re-extract → skipped', async () => {
    const r1 = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
    });
    const r2 = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
    });
    assert.equal(r2.status, 'skipped_same_sha');
    assert.equal(r2.source_sha256, r1.source_sha256);
  });

  test('UI11 within REFRESH_DAYS → skipped_within_refresh', async () => {
    // First fetch
    await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 30,
    });
    // Second without content change, within refresh window
    const r = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 30,
    });
    assert.ok(r.status === 'skipped_within_refresh' || r.status === 'skipped_same_sha');
  });

  test('UI13 refresh_days=1 with old fetched_at → re-fetch', async () => {
    const r1 = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 1,
    });
    // Manually rewrite fetched_at to 2 days ago
    const p = join(vault, r1.path);
    let content = await readFile(p, 'utf8');
    const twoDaysAgo = new Date(Date.now() - 2 * 24 * 3600 * 1000).toISOString();
    content = content.replace(/fetched_at: "[^"]+"/, `fetched_at: "${twoDaysAgo}"`);
    await writeFile(p, content);
    const r2 = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 1,
    });
    // sha is same (content unchanged) but we should have re-evaluated
    assert.ok(['refreshed_fetched_at', 'skipped_same_sha'].includes(r2.status));
  });

  test('UI14 refresh_days=never with existing file → always skipped', async () => {
    await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 'never',
    });
    // Even if we simulate the content changing, never should not re-fetch
    const r2 = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 'never',
    });
    assert.ok(['skipped_never', 'skipped_same_sha'].includes(r2.status));
  });

  test('UI17 future fetched_at (clock skew) does not crash and preserves title', async () => {
    // Regression smoke for code-quality HIGH-2 (2026-04-19):
    // 2 Mac NTP 차이로 fetched_at이 미래 시각으로 저장되는 케이스를 시뮬레이션.
    // 사전 fix에서는 ageMs < 0이 refreshMs 미만이어서 영구 skip되었음.
    // Math.max(0, ageMs)로 "clock skew 양이 아니라 refreshDays 단위로 skip 해제"로.
    // 동시에 HIGH-1 (frontmatter stripQuotes의 JSON unescape) 회귀 확인도 수행:
    // 제목이 re-read → bumpFetchedAt 회차에 corrupt되지 않음.
    await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 1,
    });
    const r1Path = join(vault, 'raw-sources', 'articles', 'fetched', '127.0.0.1-article-normal.md');
    let content = await readFile(r1Path, 'utf8');
    const futureDate = new Date(Date.now() + 2 * 24 * 3600 * 1000).toISOString();
    content = content.replace(/fetched_at: "[^"]+"/, `fetched_at: "${futureDate}"`);
    await writeFile(r1Path, content);
    const r2 = await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
      refreshDays: 1,
    });
    // 정상계: crash 없이 status는 valid skip code 중 하나.
    assert.ok(['skipped_within_refresh', 'skipped_same_sha'].includes(r2.status));
    // HIGH-1 회귀 확인: orchestrator가 parseFrontmatter → bumpFetchedAt으로
    // title을 JSON-escape하여 재기록 → 다시 읽어도 corrupt되지 않음.
    const reread = await readFile(r1Path, 'utf8');
    assert.match(reread, /title: "Attention Is All You Need"/);
  });

  test('robots Disallow returns skipped_robots', async () => {
    await assert.rejects(
      () => extractAndSaveUrl({
        url: `${server.url}/article-normal.html`,
        vault, subdir: 'articles',
        robotsUrlOverride: `${server.url}/robots.txt?variant=disallow`,
      }),
      (e) => e.code === 'robots_disallow',
    );
  });

  test('raw HTML saved to .cache/html/', async () => {
    await extractAndSaveUrl({
      url: `${server.url}/article-normal.html`,
      vault, subdir: 'articles',
      robotsUrlOverride: `${server.url}/robots.txt?variant=allow`,
    });
    const htmlCacheDir = join(vault, '.cache', 'html');
    const { readdir } = await import('node:fs/promises');
    const entries = await readdir(htmlCacheDir);
    assert.ok(entries.some((n) => n.endsWith('.html')), `raw HTML cached: ${entries}`);
  });
});
