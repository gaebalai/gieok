// gieok_write_note — Claude Desktop에서 온 "메모를 Wiki에 저장해"를 받아,
// session-logs/에 mcp-note 형식으로 기록한다. 다음 auto-ingest가 주워서 wiki/에 구조화한다.

import { mkdir, open, rename, stat } from 'node:fs/promises';
import { hostname } from 'node:os';
import { join, dirname } from 'node:path';
import { z } from 'zod';
import { assertInsideSessionLogs } from '../lib/vault-path.mjs';
import { applyMasks } from '../lib/masking.mjs';
import { serializeFrontmatter } from '../lib/frontmatter.mjs';

const MAX_TITLE = 200;
const MAX_BODY = 65536;
const MAX_TAGS = 16;
const MAX_TAG_LEN = 32;
const MAX_SLUG_LEN = 50;

export const WRITE_NOTE_TOOL_DEF = {
  name: 'gieok_write_note',
  title: 'Save a GIEOK note (recommended write tool)',
  description:
    'Append a memo to GIEOK session-logs/. The next auto-ingest cycle will structure it into wiki/. ' +
    'PREFER THIS over gieok_write_wiki for normal note-taking. ' +
    'Use this when the user asks to "save", "remember", or "add to my wiki" without specifying a particular page. ' +
    'Returns the path immediately, but the structured wiki page appears only after the next ingest run.',
  inputShape: {
    title: z.string().min(1).max(MAX_TITLE),
    body: z.string().min(1).max(MAX_BODY),
    tags: z.array(z.string().min(1).max(MAX_TAG_LEN)).max(MAX_TAGS).optional(),
    source: z
      .string()
      .max(64)
      .optional()
      .describe('Origin label, e.g. "claude-desktop". Stored in frontmatter.'),
  },
};

export async function handleWriteNote(vault, args) {
  validate(args);
  // MASK_RULES를 title / body / tags 모두에 적용 (Desktop에서 실수로 붙여넣은
  // 비밀이 frontmatter / heading / 본문 어디에도 남지 않도록 한다).
  const title = applyMasks(String(args.title).trim());
  const body = applyMasks(String(args.body));
  const tags = Array.isArray(args.tags)
    ? dedupeStrings(args.tags).map(applyMasks)
    : [];
  const source = (args.source ?? 'claude-desktop').trim() || 'claude-desktop';

  const slug = makeSlug(title);
  const sessionLogsDir = join(vault, 'session-logs');
  await mkdir(sessionLogsDir, { recursive: true, mode: 0o700 });
  const baseName = `${nowStamp()}-mcp-${slug}`;
  const finalName = await pickAvailableName(sessionLogsDir, baseName);

  // 경계 체크 (realpath는 상위 디렉터리를 경유하여 해결된다)
  await assertInsideSessionLogs(vault, finalName);

  const finalPath = join(sessionLogsDir, finalName);
  const frontmatter = {
    type: 'mcp-note',
    source,
    created: new Date().toISOString(),
    hostname: hostname(),
    ingested: false,
    related: [],
    tags,
  };
  const content = serializeFrontmatter(frontmatter, `\n# ${title}\n\n${body.replace(/\s+$/, '')}\n`);

  const tmpPath = `${finalPath}.tmp.${process.pid}.${Date.now()}`;
  const handle = await open(tmpPath, 'wx', 0o600);
  try {
    await handle.writeFile(content, 'utf8');
  } finally {
    await handle.close();
  }
  await rename(tmpPath, finalPath);

  return {
    path: `session-logs/${finalName}`,
    action: 'created',
    note: 'Will be ingested into wiki/ on the next auto-ingest cycle.',
  };
}

function validate(args) {
  if (!args || typeof args !== 'object') {
    const e = new Error('args must be an object');
    e.code = 'invalid_params';
    throw e;
  }
  if (typeof args.title !== 'string' || !args.title.trim()) {
    const e = new Error('title is required');
    e.code = 'invalid_params';
    throw e;
  }
  if (args.title.length > MAX_TITLE) {
    const e = new Error(`title too long (max ${MAX_TITLE})`);
    e.code = 'invalid_params';
    throw e;
  }
  if (typeof args.body !== 'string' || !args.body) {
    const e = new Error('body is required');
    e.code = 'invalid_params';
    throw e;
  }
  if (args.body.length > MAX_BODY) {
    const e = new Error(`body too long (max ${MAX_BODY})`);
    e.code = 'invalid_params';
    throw e;
  }
  if (args.tags !== undefined && !Array.isArray(args.tags)) {
    const e = new Error('tags must be an array');
    e.code = 'invalid_params';
    throw e;
  }
}

function nowStamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
    `-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
  );
}

function makeSlug(title) {
  // 파일명에 안전한 집합 [A-Za-z0-9_-]와 Unicode letter만 남기고, 그 외는 -로 치환.
  // ..로 인한 트래버설 문자열, 경로 구분자, 제어 문자, 인용 부호 모두 제거.
  const cleaned = title
    .normalize('NFKC')
    .replace(/[^\p{L}\p{N}_-]+/gu, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '');
  let slug = cleaned;
  if ([...slug].length > MAX_SLUG_LEN) {
    slug = [...slug].slice(0, MAX_SLUG_LEN).join('');
  }
  return slug || 'untitled';
}

async function pickAvailableName(dir, baseName) {
  const candidates = [`${baseName}.md`, ...Array.from({ length: 99 }, (_, i) => `${baseName}-${i + 2}.md`)];
  for (const name of candidates) {
    try {
      await stat(join(dir, name));
    } catch (err) {
      if (err.code === 'ENOENT') return name;
      throw err;
    }
  }
  // 100개 이상의 파일명 충돌은 비정상
  const e = new Error('too many filename collisions');
  e.code = 'collision_overflow';
  throw e;
}

function dedupeStrings(arr) {
  const seen = new Set();
  const out = [];
  for (const x of arr) {
    if (typeof x !== 'string') continue;
    const t = x.trim();
    if (!t || seen.has(t)) continue;
    seen.add(t);
    out.push(t);
    if (out.length >= MAX_TAGS) break;
  }
  return out;
}
