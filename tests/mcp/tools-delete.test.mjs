// tools-delete.test.mjs — gieok_delete 핸들러의 단위 테스트

import { test, describe, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile, readdir, stat, readFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(__dirname, '..', '..', 'mcp');

const { handleDelete } = await import(join(MCP_DIR, 'tools', 'delete.mjs'));

let workspace, vault;

beforeEach(async () => {
  workspace = await mkdtemp(join(tmpdir(), 'gieok-mcp-del-'));
  vault = join(workspace, 'vault');
  await mkdir(join(vault, 'wiki', 'concepts'), { recursive: true });
  await writeFile(join(vault, 'wiki', 'index.md'), '# Index\n\n- [[Foo]]\n');
});

async function cleanup() {
  if (workspace) await rm(workspace, { recursive: true, force: true });
}

describe('gieok_delete', () => {
  test('MCP23 archives a wiki page to wiki/.archive/', async () => {
    try {
      await writeFile(join(vault, 'wiki', 'concepts', 'orphan.md'),
        '---\ntitle: Orphan\n---\n\n# Orphan\n');
      const r = await handleDelete(vault, { path: 'concepts/orphan.md' });
      assert.match(r.archivedPath, /^wiki\/\.archive\/concepts\/orphan-/);
      assert.deepEqual(r.brokenLinks, []);
      // 원본 파일이 없음
      await assert.rejects(stat(join(vault, 'wiki', 'concepts', 'orphan.md')));
      // .archive 아래로 이동 완료
      const archiveEntries = await readdir(join(vault, 'wiki', '.archive', 'concepts'));
      assert.equal(archiveEntries.length, 1);
      assert.match(archiveEntries[0], /^orphan-\d{4}-\d{2}-\d{2}T/);
      // .archive 디렉터리 permission
      const archSt = await stat(join(vault, 'wiki', '.archive'));
      assert.equal(archSt.mode & 0o777, 0o700);
    } finally { await cleanup(); }
  });

  test('MCP24 rejects deleting wiki/index.md', async () => {
    try {
      await assert.rejects(
        handleDelete(vault, { path: 'index.md' }),
        (err) => err.code === 'cannot_delete_index',
      );
      // also "wiki/index.md" form
      await assert.rejects(
        handleDelete(vault, { path: 'wiki/index.md' }),
        (err) => err.code === 'cannot_delete_index' || err.code === 'path_traversal' || err.code === 'invalid_path',
      );
    } finally { await cleanup(); }
  });

  test('MCP25 detects wikilink references and rejects when force=false', async () => {
    try {
      await writeFile(join(vault, 'wiki', 'foo.md'),
        '---\ntitle: Foo\n---\n\n# Foo\n');
      await writeFile(join(vault, 'wiki', 'bar.md'),
        'see [[Foo]] and [[Foo]] again\n');
      await assert.rejects(
        handleDelete(vault, { path: 'foo.md' }),
        (err) => {
          if (err.code !== 'broken_links_detected') return false;
          const links = err.data?.brokenLinks ?? [];
          return links.some((x) => x.sourcePath === 'wiki/bar.md' && x.occurrences === 2);
        },
      );
      // index.md는 - [[Foo]]를 가지고 있어 참조되지만, force=false이므로 아직 archived 되지 않음
      await assert.ok((await readdir(join(vault, 'wiki'))).includes('foo.md'));
    } finally { await cleanup(); }
  });

  test('MCP26 archives even with references when force=true', async () => {
    try {
      await writeFile(join(vault, 'wiki', 'foo.md'),
        '---\ntitle: Foo\n---\n\n# Foo\n');
      await writeFile(join(vault, 'wiki', 'bar.md'),
        'see [[Foo]]\n');
      // beforeEach의 index.md에도 [[Foo]]가 있으므로 broken links는
      // bar.md와 index.md의 2개 소스
      const r = await handleDelete(vault, { path: 'foo.md', force: true });
      assert.match(r.archivedPath, /^wiki\/\.archive\/foo-/);
      assert.equal(r.brokenLinks.length, 2);
      const sources = r.brokenLinks.map((x) => x.sourcePath).sort();
      assert.deepEqual(sources, ['wiki/bar.md', 'wiki/index.md']);
    } finally { await cleanup(); }
  });

  test('MCP26b detects wikilink references from raw-sources/fetched/ (HIGH-a1)', async () => {
    // 2026-04-20 HIGH-a1 regression test: gieok_delete의 broken-link scan은
    // wiki/만 탐색했기에 `raw-sources/<subdir>/fetched/*.md`에서
    // wiki 페이지로의 wikilink가 silent orphan화되는 경로가 있었음.
    // 본 테스트는 fetched/ 아래 MD에 [[Foo]]가 있으면 검출됨을 확인한다.
    try {
      await writeFile(join(vault, 'wiki', 'foo.md'),
        '---\ntitle: Foo\n---\n\n# Foo\n');
      const fetchedDir = join(vault, 'raw-sources', 'articles', 'fetched');
      await mkdir(fetchedDir, { recursive: true });
      await writeFile(join(fetchedDir, 'evil.com-article.md'),
        '---\nsource_url: "https://evil.com/"\n---\n\n# evil article\n\nsee [[Foo]]\n');
      await assert.rejects(
        handleDelete(vault, { path: 'foo.md' }),
        (err) => {
          if (err.code !== 'broken_links_detected') return false;
          const links = err.data?.brokenLinks ?? [];
          const fetchedLink = links.find(
            (x) => x.sourcePath === 'raw-sources/articles/fetched/evil.com-article.md'
          );
          if (!fetchedLink) return false;
          assert.equal(fetchedLink.occurrences, 1);
          assert.equal(fetchedLink.inWiki, false, 'fetched/는 inWiki: false로 구분된다');
          return true;
        },
      );
    } finally { await cleanup(); }
  });

  test('MCP26d scanReferences skips files > 2MB and records them (NEW-M1)', async () => {
    // 2026-04-20 NEW-M1 regression test: HIGH-a1 fix로 vault 전체 walk로
    // 확장된 scanReferences가 attacker-controlled한 거대 fetched MD를
    // size cap 없이 readFile하면 DoS가 되는 경로를 차단.
    // 2MB 초과 파일은 skip하고 skippedLargeFiles[]에 기록한다.
    try {
      await writeFile(join(vault, 'wiki', 'foo.md'),
        '---\ntitle: Foo\n---\n\n# Foo\n');
      const fetchedDir = join(vault, 'raw-sources', 'articles', 'fetched');
      await mkdir(fetchedDir, { recursive: true });
      // 2.5MB MD 생성 (안에는 [[Foo]]를 포함하지만 size cap으로 검출되지 않음)
      const bigPath = join(fetchedDir, 'evil.com-huge.md');
      const marker = '\n\nsee [[Foo]]\n';
      // 2.5MB padding + wikilink marker
      await writeFile(bigPath, 'x'.repeat(2_500_000) + marker);
      // 일반 size MD에도 wikilink를 두고, 이쪽은 검출된다
      await writeFile(join(fetchedDir, 'normal.com-small.md'),
        '---\nsource_url: "https://normal.com/"\n---\n\nsee [[Foo]]\n');
      await assert.rejects(
        handleDelete(vault, { path: 'foo.md' }),
        (err) => {
          if (err.code !== 'broken_links_detected') return false;
          const links = err.data?.brokenLinks ?? [];
          const skipped = err.data?.skippedLargeFiles ?? [];
          // 2.5MB MD는 brokenLinks에 실리지 않음
          const bigInLinks = links.find((x) =>
            x.sourcePath === 'raw-sources/articles/fetched/evil.com-huge.md'
          );
          if (bigInLinks) return false;
          // 대신 skippedLargeFiles에 기록됨
          const bigInSkipped = skipped.find((x) =>
            x.sourcePath === 'raw-sources/articles/fetched/evil.com-huge.md'
          );
          if (!bigInSkipped) return false;
          assert.ok(bigInSkipped.size > 2_000_000,
            'skippedLargeFiles[].size must reflect actual file size');
          // 일반 size MD는 계속 검출됨
          const smallInLinks = links.find((x) =>
            x.sourcePath === 'raw-sources/articles/fetched/normal.com-small.md'
          );
          return smallInLinks !== undefined;
        },
      );
    } finally { await cleanup(); }
  });

  test('MCP26e scanReferences records unreadable files in skippedUnreadable (L-2)', async () => {
    // 2026-04-21 L-2 regression test: readFile 실패 (EACCES / EIO / ENOENT) 가
    // silent catch 로 덮여서 operator 가 알아차리지 못하는 경로를 차단.
    // chmod 0 (permission denied) 인 file 을 walk 에 포함시켜 skippedUnreadable[] 에
    // 기록되는 것을 확인한다. macOS 에서 root 이외이면 EACCES 를 확실히 유발할 수 있다.
    try {
      await writeFile(join(vault, 'wiki', 'foo.md'),
        '---\ntitle: Foo\n---\n\n# Foo\n');
      const fetchedDir = join(vault, 'raw-sources', 'articles', 'fetched');
      await mkdir(fetchedDir, { recursive: true });
      // 일반 size & 읽기 불가능한 MD (permission denied)
      const unreadablePath = join(fetchedDir, 'evil.com-locked.md');
      await writeFile(unreadablePath, '---\nsource_url: "https://evil.com/"\n---\n\nsee [[Foo]]\n');
      await chmod(unreadablePath, 0o000);
      // 일반 size 의 읽기 가능한 MD 에도 wikilink 를 넣어 brokenLinks 쪽은 발화하게 한다
      await writeFile(join(fetchedDir, 'normal.com-small.md'),
        '---\nsource_url: "https://normal.com/"\n---\n\nsee [[Foo]]\n');

      try {
        await assert.rejects(
          handleDelete(vault, { path: 'foo.md' }),
          (err) => {
            if (err.code !== 'broken_links_detected') return false;
            const unreadable = err.data?.skippedUnreadable ?? [];
            // 읽기 불가능 file 이 skippedUnreadable[] 에 실리는 것
            const locked = unreadable.find((x) =>
              x.sourcePath === 'raw-sources/articles/fetched/evil.com-locked.md'
            );
            if (!locked) return false;
            assert.ok(typeof locked.error === 'string' && locked.error.length > 0,
              'skippedUnreadable[].error must be a non-empty string');
            // 읽기 가능 file 은 brokenLinks 에 실리는 것
            const links = err.data?.brokenLinks ?? [];
            const smallInLinks = links.find((x) =>
              x.sourcePath === 'raw-sources/articles/fetched/normal.com-small.md'
            );
            return smallInLinks !== undefined;
          },
        );
      } finally {
        // cleanup 전에 permission 을 되돌리지 않으면 rm 이 실패한다
        await chmod(unreadablePath, 0o644).catch(() => {});
      }
    } finally { await cleanup(); }
  });

  test('MCP26c excludes .cache / session-logs / .git from scanReferences', async () => {
    // 2026-04-20: HIGH-a1 fix로 scanReferences를 vault 루트로 확장했으므로,
    // 제외 디렉터리 (.cache / session-logs / .git / node_modules)가 잘못
    // 탐색 대상에 들어가지 않음을 확인한다 (attacker-controlled cache HTML이
    // broken-link 스캔에 실리면 DoS / 오동작의 원인이 됨).
    try {
      await writeFile(join(vault, 'wiki', 'foo.md'),
        '---\ntitle: Foo\n---\n\n# Foo\n');
      const cacheDir = join(vault, '.cache', 'html');
      await mkdir(cacheDir, { recursive: true });
      // .cache/html/에 [[Foo]]를 포함한 HTML-like MD를 두어도 검출되지 않아야 함
      await writeFile(join(cacheDir, 'noise.md'), 'cache [[Foo]] noise\n');
      const logsDir = join(vault, 'session-logs');
      await mkdir(logsDir, { recursive: true });
      await writeFile(join(logsDir, '2026-04-20.md'), 'log [[Foo]]\n');
      // wiki/ 내 기존 index.md의 [[Foo]]가 있으므로 broken_links_detected가 발화할 것으로 예상
      await assert.rejects(
        handleDelete(vault, { path: 'foo.md' }),
        (err) => {
          if (err.code !== 'broken_links_detected') return false;
          const links = err.data?.brokenLinks ?? [];
          // .cache / session-logs 출처의 link는 포함되지 않음
          const bogus = links.find(
            (x) => x.sourcePath.startsWith('.cache/') || x.sourcePath.startsWith('session-logs/')
          );
          return bogus === undefined;
        },
      );
    } finally { await cleanup(); }
  });

  test('rejects non-existent file', async () => {
    try {
      await assert.rejects(
        handleDelete(vault, { path: 'no-such.md' }),
        (err) => err.code === 'file_not_found',
      );
    } finally { await cleanup(); }
  });

  test('rejects path traversal', async () => {
    try {
      await assert.rejects(
        handleDelete(vault, { path: '../session-logs/x.md' }),
        (err) => err.code === 'path_traversal' || err.code === 'invalid_path' || err.code === 'invalid_params',
      );
    } finally { await cleanup(); }
  });
});
