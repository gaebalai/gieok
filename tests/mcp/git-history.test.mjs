// git-history.test.mjs — lib/git-history.mjs 의 유닛 테스트 (Phase D α V-1)
//
// 실행: node --test tools/claude-brain/tests/mcp/git-history.test.mjs
//
// 방침:
//   - 실 Vault 에 접근하지 않음 (mktemp -d 로 fixture git repo 생성)
//   - 네트워크 없음
//   - trap 상당으로 tmpdir cleanup
//   - spawn 기반 git 호출은 실기 git 으로 검증 (git 미설치 환경에서는 skip)
//
// 케이스 (VIZ-GH-1 ~ 8):
//   VIZ-GH-1: 비 git dir 에서 isGitRepo() === false
//   VIZ-GH-2: git init 직후 isGitRepo() === true
//   VIZ-GH-3: commit 이력을 getFileHistory() 가 시계열로 반환
//   VIZ-GH-4: subPath filter 작동 (wiki/ 한정으로 일부 commit 만)
//   VIZ-GH-5: getFileContentAtCommit() 으로 과거 commit 내용 취득, 없으면 null
//   VIZ-GH-6: listFilesAtCommit() 이 지정 commit 의 md 파일 나열
//   VIZ-GH-7: invalid sha 는 throw
//   VIZ-GH-8: parseGitLogOutput 단위 (stdout parser)

import { test, describe, before } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  isGitRepo,
  getFileHistory,
  getFileContentAtCommit,
  listFilesAtCommit,
  parseGitLogOutput,
} from '../../mcp/lib/git-history.mjs';

// helper: spawn 으로 git 명령 실행, exit code 0 대기
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

// git 이 PATH 에 없는 환경에서의 조기 skip 판정
async function hasGit() {
  return new Promise((resolve) => {
    const child = spawn('git', ['--version'], { stdio: 'ignore' });
    child.on('error', () => resolve(false));
    child.on('close', (code) => resolve(code === 0));
  });
}

async function makeFixtureRepo() {
  const root = await mkdtemp(join(tmpdir(), 'gieok-git-history-test-'));
  await runCmd(root, 'git', ['init', '-b', 'main']);
  await runCmd(root, 'git', ['config', 'user.email', 'test@example.com']);
  await runCmd(root, 'git', ['config', 'user.name', 'Test User']);
  return root;
}

describe('git-history (Phase D α V-1)', () => {
  let gitAvailable = true;

  before(async () => {
    gitAvailable = await hasGit();
  });

  test('VIZ-GH-1: 비 git dir 에서 isGitRepo() === false', async () => {
    if (!gitAvailable) return;
    const root = await mkdtemp(join(tmpdir(), 'gieok-git-nongit-'));
    try {
      const ok = await isGitRepo(root);
      assert.equal(ok, false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-GH-2: git init 후 isGitRepo() === true', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      const ok = await isGitRepo(root);
      assert.equal(ok, true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-GH-3: commit 이력이 시계열로 반환 (최신 순)', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await mkdir(join(root, 'wiki'), { recursive: true });
      await writeFile(join(root, 'wiki', 'a.md'), '# A\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'first']);

      await new Promise((r) => setTimeout(r, 1100)); // 1초 이상 간격을 두어 commit 시각 차별화
      await writeFile(join(root, 'wiki', 'b.md'), '# B\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'second']);

      const commits = await getFileHistory(root, { subPath: 'wiki/' });
      assert.equal(commits.length, 2);
      // 최신 순 (second 가 선두)
      assert.equal(commits[0].subject, 'second');
      assert.equal(commits[1].subject, 'first');
      // timestamp 내림차순
      assert.ok(commits[0].timestamp >= commits[1].timestamp);
      // files 배열에 touched file 포함
      assert.ok(commits[0].files.includes('wiki/b.md'));
      assert.ok(commits[1].files.includes('wiki/a.md'));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-GH-4: subPath filter — 비 wiki/ commit 은 제외', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await mkdir(join(root, 'wiki'), { recursive: true });
      await mkdir(join(root, 'other'), { recursive: true });
      await writeFile(join(root, 'wiki', 'x.md'), '# X\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'wiki change']);

      await new Promise((r) => setTimeout(r, 1100));
      await writeFile(join(root, 'other', 'y.md'), '# Y\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'other change']);

      const commits = await getFileHistory(root, { subPath: 'wiki/' });
      assert.equal(commits.length, 1);
      assert.equal(commits[0].subject, 'wiki change');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-GH-5: getFileContentAtCommit() — 과거 commit 내용 취득, 부재 시 null', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await mkdir(join(root, 'wiki'), { recursive: true });
      await writeFile(join(root, 'wiki', 'hot.md'), '# Version 1\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'v1']);
      const commits1 = await getFileHistory(root, { subPath: 'wiki/' });
      const v1sha = commits1[0].sha;

      await new Promise((r) => setTimeout(r, 1100));
      await writeFile(join(root, 'wiki', 'hot.md'), '# Version 2\n');
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'v2']);
      const commits2 = await getFileHistory(root, { subPath: 'wiki/' });
      const v2sha = commits2[0].sha;

      // v1 시점 내용 취득
      const v1 = await getFileContentAtCommit(root, v1sha, 'wiki/hot.md');
      assert.match(v1, /Version 1/);

      // v2 시점 내용 취득
      const v2 = await getFileContentAtCommit(root, v2sha, 'wiki/hot.md');
      assert.match(v2, /Version 2/);

      // 없는 file → null
      const nada = await getFileContentAtCommit(root, v1sha, 'wiki/does-not-exist.md');
      assert.equal(nada, null);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-GH-6: listFilesAtCommit() — 지정 commit 의 md 나열', async () => {
    if (!gitAvailable) return;
    const root = await makeFixtureRepo();
    try {
      await mkdir(join(root, 'wiki', 'concepts'), { recursive: true });
      await writeFile(join(root, 'wiki', 'index.md'), '# Index\n');
      await writeFile(join(root, 'wiki', 'concepts', 'jwt.md'), '# JWT\n');
      await writeFile(join(root, 'wiki', 'concepts', 'oauth.md'), '# OAuth\n');
      await writeFile(join(root, 'wiki', 'image.png'), 'binary\n'); // 비 md
      await runCmd(root, 'git', ['add', '-A']);
      await runCmd(root, 'git', ['commit', '-m', 'init']);
      const commits = await getFileHistory(root, { subPath: 'wiki/' });
      const sha = commits[0].sha;

      const files = await listFilesAtCommit(root, sha, { subPath: 'wiki/' });
      // md + png 모두 반환 (호출 측에서 md filter 하는 설계)
      assert.ok(files.includes('wiki/index.md'));
      assert.ok(files.includes('wiki/concepts/jwt.md'));
      assert.ok(files.includes('wiki/concepts/oauth.md'));
      assert.ok(files.includes('wiki/image.png'));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('VIZ-GH-7: invalid sha 는 throw', async () => {
    await assert.rejects(
      () => getFileContentAtCommit('/tmp', 'not-a-sha', 'wiki/x.md'),
      /invalid sha/,
    );
    await assert.rejects(
      () => listFilesAtCommit('/tmp', 'xyz!!!', { subPath: 'wiki/' }),
      /invalid sha/,
    );
  });

  test('VIZ-GH-8: parseGitLogOutput unit (stdout parser)', () => {
    const stdout =
      'COMMIT\x1fabc123def456\x1fabc123d\x1f1700000000\x1fAlice\x1ffirst commit\nwiki/a.md\nwiki/b.md\n\n' +
      'COMMIT\x1ffeed1234\x1ffeed123\x1f1700000100\x1fBob\x1fsecond commit\nwiki/c.md\n\n';
    const commits = parseGitLogOutput(stdout);
    assert.equal(commits.length, 2);
    assert.equal(commits[0].sha, 'abc123def456');
    assert.equal(commits[0].shortSha, 'abc123d');
    assert.equal(commits[0].timestamp, 1700000000 * 1000);
    assert.equal(commits[0].author, 'Alice');
    assert.equal(commits[0].subject, 'first commit');
    assert.deepEqual(commits[0].files, ['wiki/a.md', 'wiki/b.md']);
    assert.equal(commits[1].sha, 'feed1234');
    assert.deepEqual(commits[1].files, ['wiki/c.md']);
  });
});
