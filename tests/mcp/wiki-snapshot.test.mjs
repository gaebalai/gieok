// wiki-snapshot.test.mjs — lib/wiki-snapshot.mjs 의 유닛 테스트 (Phase D α V-1)
//
// 실행: node --test tools/claude-brain/tests/mcp/wiki-snapshot.test.mjs
//
// 케이스 (VIZ-WS-1 ~ 8):
//   VIZ-WS-1: 단일 commit snapshot 이 pages + links 를 정확히 추출
//   VIZ-WS-2: frontmatter 의 secret-like 값이 applyMasks 로 복면화
//   VIZ-WS-3: wikilinks 가 빈 본문 / alias 포함도 처리
//   VIZ-WS-4~6: diffSnapshots — 추가/삭제/modified + link diff
//   VIZ-WS-7: diffSnapshots — page 삭제를 정확히 기록
//   VIZ-WS-8: invalid sha 는 throw

import { test, describe, before } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { buildWikiSnapshot, diffSnapshots } from '../../mcp/lib/wiki-snapshot.mjs';
import { getFileHistory } from '../../mcp/lib/git-history.mjs';

function runCmd(cwd, cmd, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, stdio: 'ignore' });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} ${args.join(' ')} exited ${code}`));
    });
  });
}

async function hasGit() {
  return new Promise((resolve) => {
    const child = spawn('git', ['--version'], { stdio: 'ignore' });
    child.on('error', () => resolve(false));
    child.on('close', (code) => resolve(code === 0));
  });
}

async function makeFixtureRepo() {
  const root = await mkdtemp(join(tmpdir(), 'gieok-wiki-snapshot-test-'));
  await runCmd(root, 'git', ['init', '-b', 'main']);
  await runCmd(root, 'git', ['config', 'user.email', 'test@example.com']);
  await runCmd(root, 'git', ['config', 'user.name', 'Test User']);
  await mkdir(join(root, 'wiki', 'concepts'), { recursive: true });
  return root;
}

describe('wiki-snapshot (Phase D α V-1)', () => {
  let gitAvailable = true;

  before(async () => {
    gitAvailable = await hasGit();
  });

  test('VIZ-WS-1: 단일 commit snapshot 이 pages + links 를 추출', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await writeFile(
        join(root, 'wiki', 'index.md'),
        `---
title: Wiki Index
type: index
---

# Wiki

- [[concepts/jwt]]
- [[concepts/oauth]]
`,
      );
      await writeFile(
        join(root, 'wiki', 'concepts', 'jwt.md'),
        `---
type: concept
tags: [auth, security]
---

# JWT

관련: [[oauth]]
`,
      );
      await writeFile(
        join(root, 'wiki', 'concepts', 'oauth.md'),
        `---
type: concept
tags: [auth]
---

# OAuth
`,
      );
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'init wiki']);

      const commits = await getFileHistory(root, { subPath: 'wiki/' });
      const sha = commits[0].sha;
      const snap = await buildWikiSnapshot(root, sha);

      assert.equal(snap.sha, sha);
      assert.equal(snap.pages.length, 3);

      const byName = new Map(snap.pages.map((p) => [p.name, p]));
      assert.ok(byName.has('index'));
      assert.ok(byName.has('jwt'));
      assert.ok(byName.has('oauth'));

      // frontmatter 전개
      assert.equal(byName.get('jwt').type, 'concept');
      assert.deepEqual(byName.get('jwt').tags, ['auth', 'security']);

      // wikilinks
      assert.deepEqual(byName.get('index').wikilinks.sort(), ['concepts/jwt', 'concepts/oauth']);
      assert.deepEqual(byName.get('jwt').wikilinks, ['oauth']);

      // links edges: index→concepts/jwt, index→concepts/oauth, jwt→oauth
      assert.equal(snap.links.length, 3);
      const edgeSet = new Set(snap.links.map((l) => `${l.from}→${l.to}`));
      assert.ok(edgeSet.has('index→concepts/jwt'));
      assert.ok(edgeSet.has('index→concepts/oauth'));
      assert.ok(edgeSet.has('jwt→oauth'));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-WS-2: frontmatter 의 secret-like 값이 applyMasks 로 복면화', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      // frontmatter 에 fake API key 삽입 (applyMasks 가 검출하는 pattern)
      await writeFile(
        join(root, 'wiki', 'leaky.md'),
        `---
type: note
debug_key: "sk-ant-api03-0123456789abcdefghij0123456789abcdefghij"
---

# Leaky note
`,
      );
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'leaky']);

      const commits = await getFileHistory(root, { subPath: 'wiki/' });
      const snap = await buildWikiSnapshot(root, commits[0].sha);
      const page = snap.pages.find((p) => p.name === 'leaky');
      assert.ok(page);
      const debugKey = page.frontmatter.debug_key;
      assert.ok(!debugKey.includes('0123456789abcdef'), 'raw key leaked to snapshot');
      assert.match(debugKey, /\*{3,}/);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-WS-3: wikilinks 가 빈 본문 / alias 포함도 처리', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await writeFile(join(root, 'wiki', 'empty.md'), '# Empty\n\n(no links)\n');
      await writeFile(
        join(root, 'wiki', 'alias.md'),
        '# Alias Test\n\n[[target|Display]] 의 링크\n',
      );
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'alias']);

      const commits = await getFileHistory(root, { subPath: 'wiki/' });
      const snap = await buildWikiSnapshot(root, commits[0].sha);

      const empty = snap.pages.find((p) => p.name === 'empty');
      assert.deepEqual(empty.wikilinks, []);

      const alias = snap.pages.find((p) => p.name === 'alias');
      assert.deepEqual(alias.wikilinks, ['target']);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-WS-4/5/6: diffSnapshots — 추가/삭제/modified + link diff', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      // commit 1: 2 pages, 1 link
      await writeFile(
        join(root, 'wiki', 'a.md'),
        '---\ntype: concept\n---\n# A\n\n[[b]]\n',
      );
      await writeFile(
        join(root, 'wiki', 'b.md'),
        '---\ntype: concept\n---\n# B\n',
      );
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'v1']);
      const commits1 = await getFileHistory(root, { subPath: 'wiki/' });
      const sha1 = commits1[0].sha;

      // commit 2: add c (new page + new link), modify b (tags 추가), delete nothing
      await new Promise((r) => setTimeout(r, 1100));
      await writeFile(
        join(root, 'wiki', 'b.md'),
        '---\ntype: concept\ntags: [updated]\n---\n# B\n\n[[c]]\n',
      );
      await writeFile(
        join(root, 'wiki', 'c.md'),
        '---\ntype: concept\n---\n# C\n',
      );
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'v2']);
      const commits2 = await getFileHistory(root, { subPath: 'wiki/' });
      const sha2 = commits2[0].sha;

      const snap1 = await buildWikiSnapshot(root, sha1);
      const snap2 = await buildWikiSnapshot(root, sha2);
      const d = diffSnapshots(snap1, snap2);

      // added: c
      assert.deepEqual(d.added, ['c']);
      // modified: b (tags 추가 + wikilink 추가)
      assert.ok(d.modified.includes('b'));
      // removed: 없음
      assert.deepEqual(d.removed, []);
      // linkAdded: b→c
      assert.ok(d.linkAdded.some((l) => l.from === 'b' && l.to === 'c'));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-WS-7: diffSnapshots — page 삭제를 정확히 기록', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await writeFile(join(root, 'wiki', 'keep.md'), '# Keep\n');
      await writeFile(join(root, 'wiki', 'deleteme.md'), '# DeleteMe\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'v1']);
      const commits1 = await getFileHistory(root, { subPath: 'wiki/' });

      await new Promise((r) => setTimeout(r, 1100));
      await rm(join(root, 'wiki', 'deleteme.md'));
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'v2 deleted']);
      const commits2 = await getFileHistory(root, { subPath: 'wiki/' });

      const snap1 = await buildWikiSnapshot(root, commits1[0].sha);
      const snap2 = await buildWikiSnapshot(root, commits2[0].sha);
      const d = diffSnapshots(snap1, snap2);

      assert.deepEqual(d.removed, ['deleteme']);
      assert.deepEqual(d.added, []);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-WS-8: invalid sha 는 throw', async () => {
    await assert.rejects(
      () => buildWikiSnapshot('/tmp', 'not-a-sha'),
      /invalid sha/,
    );
  });
});
