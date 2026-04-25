// wiki-snapshot.mjs — 지정 git commit 에서의 wiki/ 하위 스냅샷을 구성
//
// 사용 예:
//   const snap = await buildWikiSnapshot(vaultDir, sha);
//   // snap = { sha, timestamp, pages: [...], links: [...] }
//
// Visualizer (Phase D α) 가 시계열 애니메이션 / diff 를 생성하기 위한 입력.
//
// 설계 원칙 (plan/claude/26042402 §Security / Trust boundary):
//   - 본문 (body) 은 snapshot 에 포함하지 않음 (frontmatter + wikilink 만, 누출 blast radius 제한)
//   - applyMasks() 를 frontmatter 값에 적용 (secret 누출 방어, 기존 GIEOK 패턴)
//   - git-history.mjs 의 spawn 기반 안전 명령 경로를 통해 read-only

import { parseFrontmatter } from './frontmatter.mjs';
import { findWikilinks } from './wikilinks.mjs';
import { maskText as applyMasks } from '../../scripts/lib/masking.mjs';
import { getFileContentAtCommit, listFilesAtCommit } from './git-history.mjs';

export class WikiSnapshotError extends Error {
  constructor(message, code = 'snapshot_error') {
    super(message);
    this.name = 'WikiSnapshotError';
    this.code = code;
  }
}

// 지정 commit 에서의 wiki/ 스냅샷을 구성
//
// 반환:
// {
//   sha: '<full sha>',
//   timestamp: <ms since epoch, 호출 측 지정 or null>,
//   pages: [{
//     path: 'wiki/concepts/jwt.md',         // vault-relative
//     name: 'jwt',                           // basename without extension
//     folder: 'wiki/concepts',               // parent folder (nav/group 용)
//     type: 'concept',                       // frontmatter type
//     tags: ['auth', 'security'],            // frontmatter tags
//     title: 'JWT Authentication',           // frontmatter title (있다면)
//     wikilinks: ['oauth2', 'session-token'],// [[wikilink]] targets (확장자 없음)
//     frontmatter: { ... applyMasks 적용됨 } // 전체 frontmatter, secret masked
//   }, ...],
//   links: [{ from: 'jwt', to: 'oauth2' }, ...]  // edges (wikilinks 로부터 파생)
// }
export async function buildWikiSnapshot(vaultDir, sha, options = {}) {
  if (typeof vaultDir !== 'string' || vaultDir.length === 0) {
    throw new WikiSnapshotError('vaultDir required', 'invalid_args');
  }
  if (typeof sha !== 'string' || !/^[0-9a-f]{4,40}$/.test(sha)) {
    throw new WikiSnapshotError('invalid sha', 'invalid_args');
  }
  const { subPath = 'wiki/', timestamp = null } = options;

  const files = await listFilesAtCommit(vaultDir, sha, { subPath });
  const mdFiles = files.filter((p) => p.endsWith('.md'));

  const pages = [];
  const linkSet = new Set(); // 중복 edges 제거용 Set of "from\x1fto"
  for (const relPath of mdFiles) {
    const content = await getFileContentAtCommit(vaultDir, sha, relPath);
    if (content === null) continue; // 취득 실패 (rename 등) 는 skip
    const page = parsePage(relPath, content);
    pages.push(page);
    for (const target of page.wikilinks) {
      linkSet.add(`${page.name}\x1f${target}`);
    }
  }

  const links = Array.from(linkSet).map((pair) => {
    const [from, to] = pair.split('\x1f');
    return { from, to };
  });

  return { sha, timestamp, pages, links };
}

// 내부: 페이지 하나 parse
// frontmatter + wikilinks 추출, applyMasks 로 secret 마스킹
function parsePage(relPath, content) {
  const parsed = parseFrontmatter(content);
  // parseFrontmatter() 는 { data, body } 를 반환 (mcp/lib/frontmatter.mjs 정전)
  const rawFrontmatter = parsed?.data ?? {};
  const body = parsed?.body ?? content;

  // frontmatter values 에 applyMasks 적용
  const masked = maskFrontmatter(rawFrontmatter);

  const name = basenameWithoutExt(relPath);
  const folder = parentFolder(relPath);
  const wikilinks = findWikilinks(body);

  return {
    path: relPath,
    name,
    folder,
    type: typeof masked.type === 'string' ? masked.type : null,
    tags: Array.isArray(masked.tags)
      ? masked.tags.filter((t) => typeof t === 'string')
      : [],
    title: typeof masked.title === 'string' ? masked.title : null,
    wikilinks,
    frontmatter: masked,
  };
}

// frontmatter 의 각 string value 에 applyMasks 적용 (shallow)
// array / nested object 는 재귀로 walk
function maskFrontmatter(obj) {
  if (obj === null || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) {
    return obj.map((v) => maskValue(v));
  }
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    out[k] = maskValue(v);
  }
  return out;
}

function maskValue(v) {
  if (typeof v === 'string') return applyMasks(v);
  if (Array.isArray(v)) return v.map((x) => maskValue(x));
  if (v !== null && typeof v === 'object') return maskFrontmatter(v);
  return v;
}

function basenameWithoutExt(relPath) {
  const last = relPath.split('/').pop() ?? '';
  return last.replace(/\.md$/, '');
}

function parentFolder(relPath) {
  const parts = relPath.split('/');
  parts.pop();
  return parts.join('/');
}

// 2 snapshot 간 diff 계산 (View 2 Diff Viewer 용)
// 반환: { added: [names], removed: [names], modified: [names], linkAdded: [{from,to}], linkRemoved: [{from,to}] }
export function diffSnapshots(beforeSnap, afterSnap) {
  if (!beforeSnap || !afterSnap) {
    throw new WikiSnapshotError('two snapshots required', 'invalid_args');
  }
  const beforeByName = indexByName(beforeSnap.pages);
  const afterByName = indexByName(afterSnap.pages);

  const added = [];
  const removed = [];
  const modified = [];

  for (const [name, page] of afterByName) {
    if (!beforeByName.has(name)) {
      added.push(name);
    } else {
      // shallow compare: tags / type / title / wikilinks 배열
      const prev = beforeByName.get(name);
      if (
        prev.type !== page.type ||
        prev.title !== page.title ||
        !arrayEqual(prev.tags, page.tags) ||
        !arrayEqual(prev.wikilinks, page.wikilinks)
      ) {
        modified.push(name);
      }
    }
  }
  for (const [name] of beforeByName) {
    if (!afterByName.has(name)) removed.push(name);
  }

  const beforeEdges = edgeSet(beforeSnap.links);
  const afterEdges = edgeSet(afterSnap.links);
  const linkAdded = [];
  const linkRemoved = [];
  for (const key of afterEdges) if (!beforeEdges.has(key)) linkAdded.push(splitEdgeKey(key));
  for (const key of beforeEdges) if (!afterEdges.has(key)) linkRemoved.push(splitEdgeKey(key));

  return { added, removed, modified, linkAdded, linkRemoved };
}

function indexByName(pages) {
  const m = new Map();
  for (const p of pages) m.set(p.name, p);
  return m;
}

function edgeSet(links) {
  const s = new Set();
  for (const l of links) s.add(`${l.from}\x1f${l.to}`);
  return s;
}

function splitEdgeKey(key) {
  const [from, to] = key.split('\x1f');
  return { from, to };
}

function arrayEqual(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return false;
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  for (let i = 0; i < sa.length; i += 1) {
    if (sa[i] !== sb[i]) return false;
  }
  return true;
}
