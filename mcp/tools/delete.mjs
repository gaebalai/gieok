// gieok_delete — wiki/<path>.md을 wiki/.archive/로 이동 (복원 가능).
// wiki/index.md은 삭제 불가. wikilink 참조가 있고 force=false이면 reject.

import { mkdir, readdir, readFile, rename, stat } from 'node:fs/promises';
import { basename, dirname, join, relative, sep } from 'node:path';
import { realpath } from 'node:fs/promises';
import { z } from 'zod';
import { assertInsideWiki } from '../lib/vault-path.mjs';
import { withLock } from '../lib/lock.mjs';
import { findWikilinks } from '../lib/wikilinks.mjs';
import { parseFrontmatter } from '../lib/frontmatter.mjs';

export const DELETE_TOOL_DEF = {
  name: 'gieok_delete',
  title: 'Archive a GIEOK wiki page',
  description:
    'Move a wiki page to wiki/.archive/<orig>-<UTC>.md (recoverable). ' +
    'If other pages contain [[<title>]] / [[<stem>]] references and force=false, the call is rejected with the list of broken links.',
  inputShape: {
    path: z
      .string()
      .min(1)
      .max(512)
      .regex(/^[\p{L}\p{N}/._ -]+\.md$/u)
      .describe('Relative path under wiki/, e.g. "concepts/foo.md".'),
    force: z.boolean().optional(),
  },
};

export async function handleDelete(vault, args) {
  validate(args);
  const path = args.path;
  const force = args.force === true;

  if (path === 'index.md' || path === 'wiki/index.md') {
    const e = new Error('cannot delete wiki/index.md');
    e.code = 'cannot_delete_index';
    throw e;
  }

  const abs = await assertInsideWiki(vault, path);

  return withLock(vault, async () => {
    let st;
    try {
      st = await stat(abs);
    } catch (err) {
      if (err.code === 'ENOENT') {
        const e = new Error('file not found');
        e.code = 'file_not_found';
        throw e;
      }
      throw err;
    }
    if (!st.isFile()) {
      const e = new Error('not a regular file');
      e.code = 'not_a_file';
      throw e;
    }

    // index.md realpath fallback (경로 비교가 아니라 실체로 비교)
    const wikiAbs = await realpath(join(vault, 'wiki'));
    if (abs === join(wikiAbs, 'index.md')) {
      const e = new Error('cannot delete wiki/index.md');
      e.code = 'cannot_delete_index';
      throw e;
    }

    // 삭제 대상의 제목과 파일 stem을 수집
    let title = null;
    try {
      const head = await readFile(abs, 'utf8');
      const { data } = parseFrontmatter(head);
      if (typeof data.title === 'string' && data.title) title = data.title;
    } catch {
      // ignore
    }
    const stem = basename(abs, '.md');
    const targets = new Set([stem]);
    if (title) targets.add(title);

    // 2026-04-20 HIGH-a1 fix: wiki/뿐만 아니라 raw-sources/ 하위도 스캔 대상으로 한다.
    // 기능 2.2에서 `raw-sources/<subdir>/fetched/*.md`가 LLM 생성의 [[...]] wikilink를
    // 가질 수 있지만, 기존 구현에서는 wiki/만 스캔했기 때문에, fetched 쪽에서의 링크가
    // 남은 상태로 wiki 페이지를 archive하면 broken_links_detected가 발화되지 않고
    // silent orphan이 되는 문제가 있었다.
    const vaultAbs = await realpath(vault);
    const { brokenLinks, skippedLargeFiles, skippedUnreadable } =
      await scanReferences(vaultAbs, wikiAbs, abs, targets);

    if (brokenLinks.length > 0 && !force) {
      const e = new Error('broken links detected (use force=true to override)');
      e.code = 'broken_links_detected';
      e.data = { brokenLinks, skippedLargeFiles, skippedUnreadable };
      throw e;
    }

    // .archive/<orig dir>/<orig stem>-<UTC>.md로 이동
    // wikiAbs (realpath)를 기점으로 구성하여 symlink (예: /tmp -> /private/tmp)로 인한 경로 불일치를 회피
    const archiveDir = join(wikiAbs, '.archive');
    await mkdir(archiveDir, { recursive: true, mode: 0o700 });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const relFromWiki = relative(wikiAbs, abs);
    const archiveSubdir = dirname(relFromWiki);
    const archiveFinalDir = archiveSubdir === '.' ? archiveDir : join(archiveDir, archiveSubdir);
    if (archiveFinalDir !== archiveDir) {
      await mkdir(archiveFinalDir, { recursive: true, mode: 0o700 });
    }
    const archiveName = `${basename(abs, '.md')}-${stamp}.md`;
    const archiveAbs = join(archiveFinalDir, archiveName);

    await rename(abs, archiveAbs);

    return {
      archivedPath: 'wiki/' + relative(wikiAbs, archiveAbs).split(sep).join('/'),
      brokenLinks,
      skippedLargeFiles,
      skippedUnreadable,
    };
  });
}

function validate(args) {
  if (!args || typeof args !== 'object') {
    const e = new Error('args must be an object');
    e.code = 'invalid_params';
    throw e;
  }
  if (typeof args.path !== 'string' || !args.path.trim()) {
    const e = new Error('path is required');
    e.code = 'invalid_params';
    throw e;
  }
}

// 2026-04-20 NEW-M1 fix: scanReferences walker는 wiki/에 더해 raw-sources/도
// 훑게 되었지만 (HIGH-a1 fix), `raw-sources/<subdir>/fetched/*.md`는
// attacker-controlled한 HTML → Markdown 변환 출력을 포함할 수 있다. size cap 없이
// readFile(..., 'utf8')을 돌리면 500개의 큰 fetched MD가 심어진 경우에
// gieok_delete가 withLock을 장시간 쥐어 다른 MCP 조작을 블록한다 (DoS 표면 확대).
// 2MB 초과 파일은 scan 대상에서 제외: wiki/의 일반 운용에서는 개별 페이지가 이
// 크기를 초과하는 일은 거의 없고, attacker-controlled한 거대 MD만 걸러진다.
const SCAN_MAX_BYTES = 2_000_000;

async function scanReferences(vaultAbs, wikiAbs, targetAbs, targetSet) {
  // 2026-04-20 HIGH-a1 fix: vault 루트에서부터 스캔해 wiki/ + raw-sources/ 양쪽을
  // 대상으로 넣는다. session-logs / .cache / .obsidian / node_modules 등은 제외.
  const out = [];
  const skipped = [];
  // 2026-04-21 L-2 fix: readFile 실패를 silent catch 하지 않고 operator 가시성을 남긴다.
  // SCAN_MAX_BYTES (size cap) 를 통과한 뒤 readFile 이 EACCES / EIO / ENOENT
  // (symlink 끊김 등) 로 실패하면 skippedUnreadable[] 에 기록하여 caller 에 돌려준다.
  const unreadable = [];
  // 디렉터리명 제외 (최상위 및 임의 계층)
  const excludeDirs = new Set([
    '.obsidian', '.archive', '.trash', 'templates',
    '.cache', 'session-logs', 'node_modules', '.git',
  ]);
  async function walk(dir) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const dirent of entries) {
      if (excludeDirs.has(dirent.name)) continue;
      if (dirent.name.startsWith('.')) continue;
      const childAbs = join(dir, dirent.name);
      if (dirent.isDirectory()) {
        await walk(childAbs);
      } else if (dirent.isFile() && dirent.name.endsWith('.md') && childAbs !== targetAbs) {
        try {
          // NEW-M1 fix: size cap을 먼저 체크한다. st.isFile()은 readdir 쪽에서
          // 확인 완료. 2MB 초과는 readFile 없이 skipped[]에 기록하여 운영자 가시성을 남긴다.
          const st = await stat(childAbs);
          if (st.size > SCAN_MAX_BYTES) {
            const relFromVault = relative(vaultAbs, childAbs).split(sep).join('/');
            skipped.push({ sourcePath: relFromVault, size: st.size });
            continue;
          }
          const c = await readFile(childAbs, 'utf8');
          // 원본 [[<target>]]의 출현 횟수를 센다 (findWikilinks는 dedupe하므로 별도 카운트)
          let occ = 0;
          for (const m of c.matchAll(/\[\[([^\]\n]+)\]\]/g)) {
            const target = m[1].split('|')[0].split('#')[0].trim();
            if (targetSet.has(target)) occ++;
          }
          if (occ > 0) {
            // sourcePath는 vault로부터의 상대 경로. wiki/ 이외의 출처 (예: raw-sources/)
            // 는 운영자가 "어디서 참조되고 있는지" 판단할 수 있도록 prefix를 유지.
            const relFromVault = relative(vaultAbs, childAbs).split(sep).join('/');
            const inWiki = childAbs.startsWith(wikiAbs + sep) || childAbs === wikiAbs;
            out.push({
              sourcePath: relFromVault,
              occurrences: occ,
              inWiki,
            });
          }
        } catch (err) {
          // L-2 fix: silent skip 하지 않고 skippedUnreadable[] 에 기록.
          // error 필드는 운영측에서 EACCES / EIO / ENOENT 등을 구분할 수 있도록
          // code 를 우선하고, 없으면 message 선두 200 char 로 truncate 한다
          // (공격자 제어의 장대 error message 로 operator 가시성이 손상되지 않도록).
          const relFromVault = relative(vaultAbs, childAbs).split(sep).join('/');
          const errStr = typeof err?.code === 'string' && err.code
            ? err.code
            : String(err?.message ?? 'unknown').slice(0, 200);
          unreadable.push({ sourcePath: relFromVault, error: errStr });
        }
      }
    }
  }
  await walk(vaultAbs);
  return { brokenLinks: out, skippedLargeFiles: skipped, skippedUnreadable: unreadable };
}
