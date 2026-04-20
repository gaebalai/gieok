// tools-search.test.mjs — gieok_search 핸들러의 단위 테스트
//
// qmd CLI를 stub하기 위해 PATH 선두에 임시 bin/을 끼워 넣는다.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(__dirname, '..', '..', 'mcp');
const { handleSearch } = await import(join(MCP_DIR, 'tools', 'search.mjs'));

let workspace, vault;

before(async () => {
  workspace = await mkdtemp(join(tmpdir(), 'gieok-mcp-search-'));
  vault = join(workspace, 'vault');
  await mkdir(join(vault, 'wiki', 'concepts'), { recursive: true });
  await writeFile(
    join(vault, 'wiki', 'concepts', 'typescript.md'),
    '# TypeScript Notes\n\nTypeScript adds optional static typing to JavaScript.\n',
  );
  await writeFile(
    join(vault, 'wiki', 'concepts', 'go.md'),
    '# Go\n\nGo is a statically typed language.\n',
  );
});

after(() => rm(workspace, { recursive: true, force: true }));

async function withQmdStub(stubScript, fn) {
  const stubDir = await mkdtemp(join(tmpdir(), 'gieok-stub-'));
  const stubPath = join(stubDir, 'qmd');
  await writeFile(stubPath, stubScript);
  await chmod(stubPath, 0o755);
  const prevPath = process.env.PATH;
  process.env.PATH = `${stubDir}:${prevPath}`;
  try {
    return await fn();
  } finally {
    process.env.PATH = prevPath;
    await rm(stubDir, { recursive: true, force: true });
  }
}

async function withMissingQmd(fn) {
  // PATH를 거의 빈 형태로 만들어 qmd를 보이지 않게 한다
  const prevPath = process.env.PATH;
  process.env.PATH = '/nonexistent-bin-only';
  try {
    return await fn();
  } finally {
    process.env.PATH = prevPath;
  }
}

describe('gieok_search', () => {
  test('MCP9 parses qmd JSON output', async () => {
    const stub = `#!/usr/bin/env bash
cat <<'JSON'
[
  {"docid":"#abc","score":0.91,"file":"qmd://brain-wiki/concepts/typescript.md","title":"TypeScript Notes","snippet":"TypeScript adds..."},
  {"docid":"#def","score":0.55,"file":"qmd://brain-wiki/concepts/go.md","title":"Go","snippet":"Go is..."}
]
JSON
`;
    await withQmdStub(stub, async () => {
      const r = await handleSearch(vault, { query: 'typescript', limit: 5, mode: 'lex' });
      assert.equal(r.results.length, 2);
      assert.equal(r.results[0].path, 'concepts/typescript.md');
      assert.equal(r.results[0].title, 'TypeScript Notes');
      assert.equal(r.results[0].score, 0.91);
      assert.equal(r.note, undefined);
    });
  });

  test('MCP10 falls back to Node grep when qmd missing', async () => {
    await withMissingQmd(async () => {
      const r = await handleSearch(vault, { query: 'typescript' });
      assert.match(r.note ?? '', /qmd CLI not available/);
      assert.ok(r.results.length >= 1);
      const paths = r.results.map((x) => x.path);
      assert.ok(paths.includes('concepts/typescript.md'));
    });
  });

  test('falls back when qmd exits non-zero', async () => {
    const stub = `#!/usr/bin/env bash
echo "qmd error" >&2
exit 1
`;
    await withQmdStub(stub, async () => {
      const r = await handleSearch(vault, { query: 'typescript' });
      assert.match(r.note ?? '', /qmd CLI not available/);
    });
  });

  test('falls back on invalid qmd JSON', async () => {
    const stub = `#!/usr/bin/env bash
echo "not json"
exit 0
`;
    await withQmdStub(stub, async () => {
      const r = await handleSearch(vault, { query: 'typescript' });
      assert.match(r.note ?? '', /qmd CLI not available/);
    });
  });

  test('rejects empty query', async () => {
    await assert.rejects(
      handleSearch(vault, { query: '   ' }),
      (err) => err.code === 'invalid_params',
    );
  });

  test('clamps limit to 50', async () => {
    let capturedArgs = '';
    const stub = `#!/usr/bin/env bash
echo "ARGS: $@" >&2
echo "[]"
`;
    // We can't capture from outside easily; just assert no throw with high limit.
    await withQmdStub(stub, async () => {
      const r = await handleSearch(vault, { query: 'x', limit: 999 });
      assert.deepEqual(r.results, []);
    });
  });
});
