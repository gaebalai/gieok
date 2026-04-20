// detached-spawn.test.mjs — mcp/lib/detached-spawn.mjs 의 단위 테스트
//
// v0.3.5 Option B 에서 신설한 spawnDetached 헬퍼의 동작 확인.
// 설계서: plan/claude/26042004_feature-v0-3-5-early-return-design.md §구현 상세
//
// 검증 항목:
//   DS1 spawnDetached 가 PID (number) 를 반환
//   DS2 부모 프로세스가 exit 해도 자식이 계속 생존 (grandchild 생존 테스트)
//   DS3 stdout / stderr 가 logFile 에 기록됨
//   DS4 opts.env 가 자식에 propagate 됨
//   DS5 spawn 실패 (ENOENT) 는 예외로 보고됨

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, stat, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DETACHED_SPAWN_PATH = join(__dirname, '..', 'mcp', 'lib', 'detached-spawn.mjs');

const { spawnDetached } = await import(DETACHED_SPAWN_PATH);

let workspace;

before(async () => {
  workspace = await mkdtemp(join(tmpdir(), 'gieok-dspawn-'));
});

after(() => rm(workspace, { recursive: true, force: true }));

// 헬퍼: PID 가 live 인지 (signal 0 으로 OS 에 질의)
function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// 헬퍼: short sleep
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

describe('spawnDetached', () => {
  test('DS1 returns a positive integer PID', async () => {
    const logFile = join(workspace, 'ds1.log');
    const pid = await spawnDetached('/bin/sleep', ['2'], {
      logFile,
      env: { PATH: process.env.PATH ?? '/usr/bin:/bin' },
      cwd: workspace,
    });
    try {
      assert.equal(typeof pid, 'number');
      assert.ok(Number.isInteger(pid) && pid > 0, `expected positive int pid, got ${pid}`);
      assert.ok(isAlive(pid), `PID ${pid} should be alive right after spawn`);
    } finally {
      try { process.kill(pid, 'SIGKILL'); } catch { /* already dead */ }
    }
  });

  test('DS2 detached child survives parent (helper) process exit', async () => {
    const logFile = join(workspace, 'ds2.log');
    // Helper script spawns a long-running detached /bin/sleep via spawnDetached,
    // prints the grandchild pid, then exits. We verify the grandchild survives
    // the helper's exit (that's what detached + unref guarantees).
    const helperPath = join(workspace, 'ds2-helper.mjs');
    const helperSrc = `
import { spawnDetached } from ${JSON.stringify(DETACHED_SPAWN_PATH)};
const pid = await spawnDetached('/bin/sleep', ['8'], {
  logFile: ${JSON.stringify(logFile)},
  env: { PATH: process.env.PATH },
  cwd: ${JSON.stringify(workspace)},
});
process.stdout.write(String(pid));
`;
    await writeFile(helperPath, helperSrc);
    const r = spawnSync(process.execPath, [helperPath], { encoding: 'utf8' });
    assert.equal(r.status, 0, `helper exited non-zero: stderr=${r.stderr}`);
    const grandchildPid = Number.parseInt(r.stdout.trim(), 10);
    assert.ok(Number.isInteger(grandchildPid) && grandchildPid > 0,
      `helper should print pid, got: ${JSON.stringify(r.stdout)}`);

    // Helper has exited. The grandchild should still be alive because we unref'd.
    // Tiny sleep to let OS settle post-fork.
    await sleep(50);
    try {
      assert.ok(isAlive(grandchildPid),
        `grandchild ${grandchildPid} should be alive after helper exit`);
    } finally {
      try { process.kill(grandchildPid, 'SIGKILL'); } catch { /* already dead */ }
    }
  });

  test('DS3 stdout and stderr are redirected to logFile', async () => {
    const logFile = join(workspace, 'ds3.log');
    const pid = await spawnDetached(
      '/bin/sh',
      ['-c', 'echo LINE_STDOUT; echo LINE_STDERR >&2'],
      { logFile, env: { PATH: process.env.PATH ?? '/usr/bin:/bin' }, cwd: workspace },
    );
    // Wait for the child to finish and flush stdio.
    // Poll for logFile content (detached child's exit is not observable from parent).
    let content = '';
    for (let i = 0; i < 40; i++) {
      await sleep(25);
      try {
        content = await readFile(logFile, 'utf8');
        if (content.includes('LINE_STDOUT') && content.includes('LINE_STDERR')) break;
      } catch { /* not yet */ }
      if (!isAlive(pid)) break;
    }
    assert.match(content, /LINE_STDOUT/, `stdout should be captured, got: ${content}`);
    assert.match(content, /LINE_STDERR/, `stderr should be captured, got: ${content}`);
  });

  test('DS4 opts.env is propagated to the child', async () => {
    const logFile = join(workspace, 'ds4.log');
    const sentinel = 'GIEOK_DS4_SENTINEL_VALUE_12345';
    const pid = await spawnDetached(
      '/bin/sh',
      ['-c', 'echo "MARKER=${GIEOK_DS4_SENTINEL}"'],
      {
        logFile,
        env: {
          PATH: process.env.PATH ?? '/usr/bin:/bin',
          GIEOK_DS4_SENTINEL: sentinel,
        },
        cwd: workspace,
      },
    );
    let content = '';
    for (let i = 0; i < 40; i++) {
      await sleep(25);
      try {
        content = await readFile(logFile, 'utf8');
        if (content.includes(sentinel)) break;
      } catch { /* not yet */ }
      if (!isAlive(pid)) break;
    }
    assert.match(content, new RegExp(`MARKER=${sentinel}`),
      `custom env var should reach child, got: ${content}`);
  });

  test('DS5 spawn failure (missing binary) rejects with an Error', async () => {
    const logFile = join(workspace, 'ds5.log');
    await assert.rejects(
      () => spawnDetached(
        '/nonexistent/path/to/binary-does-not-exist-xyz',
        [],
        { logFile, env: { PATH: process.env.PATH ?? '/usr/bin:/bin' }, cwd: workspace },
      ),
      (err) => err instanceof Error,
    );
  });

  test('DS6 opts.logFile is required', async () => {
    await assert.rejects(
      () => spawnDetached('/bin/true', [], { env: {}, cwd: workspace }),
      (err) => err instanceof Error && /logFile/.test(err.message),
    );
  });

  test('DS7 logFile parent directory is created if missing', async () => {
    const nestedLog = join(workspace, 'ds7-nested', 'deep', 'dir', 'ds7.log');
    const pid = await spawnDetached('/bin/sh', ['-c', 'echo HELLO_NESTED'], {
      logFile: nestedLog,
      env: { PATH: process.env.PATH ?? '/usr/bin:/bin' },
      cwd: workspace,
    });
    let content = '';
    for (let i = 0; i < 40; i++) {
      await sleep(25);
      try {
        content = await readFile(nestedLog, 'utf8');
        if (content.includes('HELLO_NESTED')) break;
      } catch { /* not yet */ }
      if (!isAlive(pid)) break;
    }
    assert.match(content, /HELLO_NESTED/);
  });
});
