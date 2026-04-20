// wiki-context-injector.test.mjs — hooks/wiki-context-injector.mjs 의 유닛 테스트
//
// 실행: node --test tools/claude-brain/tests/hooks/wiki-context-injector.test.mjs
//
// 원칙:
//   - 실제 Vault 를 건드리지 않는다 (mktemp -d)
//   - 네트워크 없음
//   - 테스트 종료 시 tmpdir 을 확실히 삭제
//
// 케이스: Phase H 테스트 케이스 H1-H5
//   H1: index.md 존재 → additionalContext 에 목차가 포함된 JSON 을 stdout 출력
//   H2: index.md 부재 → 아무것도 출력하지 않고 exit 0
//   H3: OBSIDIAN_VAULT 미설정 → exit 0
//   H4: index.md 가 10,000자 초과 → Hook 쪽은 전문 출력 (잘라내기는 Claude Code 쪽)
//   H5: 출력 JSON 이 valid (JSON.parse 성공)

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const INJECTOR_PATH = join(__dirname, '..', '..', 'hooks', 'wiki-context-injector.mjs');

async function createVault() {
  const root = await mkdtemp(join(tmpdir(), 'claude-brain-injector-test-'));
  const vault = join(root, 'vault');
  await mkdir(join(vault, 'wiki'), { recursive: true });
  return { root, vault };
}

function runInjector({ vault, cwd, unsetVault = false } = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    if (unsetVault) {
      delete env.OBSIDIAN_VAULT;
    } else if (vault) {
      env.OBSIDIAN_VAULT = vault;
    }
    const child = spawn('node', [INJECTOR_PATH], {
      env,
      cwd: cwd || process.cwd(),
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d.toString()));
    child.stderr.on('data', (d) => (stderr += d.toString()));
    child.on('error', reject);
    child.on('exit', (code) => resolve({ code, stdout, stderr }));
  });
}

describe('wiki-context-injector', () => {
  test('H1: index.md 가 존재하면 additionalContext 에 목차를 포함한 JSON 을 출력한다', async () => {
    const { root, vault } = await createVault();
    try {
      const indexBody = '# Wiki Index\n\n- [[concepts/jwt-authentication]]\n- [[projects/my-saas-app]]\n';
      await writeFile(join(vault, 'wiki', 'index.md'), indexBody);

      const fakeProjectCwd = join(root, 'my-project');
      await mkdir(fakeProjectCwd, { recursive: true });
      const { code, stdout } = await runInjector({ vault, cwd: fakeProjectCwd });

      assert.equal(code, 0, 'exit code 0');
      assert.ok(stdout.length > 0, 'stdout 에 출력 있음');
      const parsed = JSON.parse(stdout);
      assert.ok(typeof parsed.additionalContext === 'string');
      assert.match(parsed.additionalContext, /지식 베이스/);
      assert.match(parsed.additionalContext, /wiki 목차/);
      assert.ok(
        parsed.additionalContext.includes(indexBody),
        'additionalContext 에 index.md 본문이 포함됨'
      );
      assert.match(parsed.additionalContext, /현재 프로젝트: my-project/);
      assert.ok(parsed.additionalContext.includes('$OBSIDIAN_VAULT/wiki/'));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('H2: index.md 가 존재하지 않으면 아무것도 출력하지 않고 exit 0', async () => {
    const { root, vault } = await createVault();
    try {
      const { code, stdout } = await runInjector({ vault });
      assert.equal(code, 0);
      assert.equal(stdout, '');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('H3: OBSIDIAN_VAULT 가 미설정이면 exit 0 으로 아무것도 출력하지 않는다', async () => {
    const { code, stdout } = await runInjector({ unsetVault: true });
    assert.equal(code, 0);
    assert.equal(stdout, '');
  });

  test('H4: index.md 가 10,000자를 초과해도 Hook 쪽은 전문 출력한다 (잘라내기는 Claude Code 쪽)', async () => {
    const { root, vault } = await createVault();
    try {
      const huge = '# Huge Index\n\n' + '- ' + 'x'.repeat(12000) + '\n';
      await writeFile(join(vault, 'wiki', 'index.md'), huge);

      const { code, stdout } = await runInjector({ vault });
      assert.equal(code, 0);
      const parsed = JSON.parse(stdout);
      assert.ok(
        parsed.additionalContext.length > 10000,
        'Hook 쪽은 잘라내지 않음 (10KB 상한은 Claude Code 쪽의 책무)'
      );
      assert.ok(parsed.additionalContext.includes(huge));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test('H5: 출력은 valid JSON 으로 parse 할 수 있다', async () => {
    const { root, vault } = await createVault();
    try {
      await writeFile(join(vault, 'wiki', 'index.md'), '# Index\n\n특수문자: "quote" \\ \n 탭\t 개행\n');
      const { code, stdout } = await runInjector({ vault });
      assert.equal(code, 0);
      assert.doesNotThrow(() => JSON.parse(stdout));
      const parsed = JSON.parse(stdout);
      assert.ok(typeof parsed.additionalContext === 'string');
      assert.ok(parsed.additionalContext.includes('"quote"'));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
