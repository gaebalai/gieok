// gieok_write_wiki — wiki/ 페이지 직접 쓰기 (즉시 반영).
// 템플릿 준수 / frontmatter 자동 부여 / wikilink 추가 / 배타 락 / 원자적 쓰기.

import { mkdir, open, readFile, readdir, rename, stat } from 'node:fs/promises';
import { join, dirname, basename, relative, sep } from 'node:path';
import { realpath } from 'node:fs/promises';
import { z } from 'zod';
import { assertInsideWiki } from '../lib/vault-path.mjs';
import { applyMasks } from '../lib/masking.mjs';
import { mergeFrontmatter, parseFrontmatter, serializeFrontmatter } from '../lib/frontmatter.mjs';
import { appendRelatedLink } from '../lib/wikilinks.mjs';
import { withLock } from '../lib/lock.mjs';
import { loadTemplate, VALID_TEMPLATES } from '../lib/templates.mjs';

const MAX_TITLE = 200;
const MAX_BODY = 65536;
const MAX_TAGS = 16;
const MAX_RELATED = 16;

export const WRITE_WIKI_TOOL_DEF = {
  name: 'gieok_write_wiki',
  title: 'Write directly to GIEOK wiki (advanced)',
  description:
    'Direct write to wiki/<path>.md with frontmatter auto-injection. ' +
    'Use ONLY when the user explicitly wants the page to appear immediately AND accepts that template/wikilink integrity is best-effort. ' +
    'PREFER gieok_write_note for normal note-taking — it routes through auto-ingest which preserves wiki coherence.',
  inputShape: {
    path: z
      .string()
      .min(1)
      .max(512)
      .regex(/^[\p{L}\p{N}/._ -]+\.md$/u)
      .describe('Relative path under wiki/, e.g. "concepts/foo.md".'),
    title: z.string().min(1).max(MAX_TITLE),
    body: z.string().min(1).max(MAX_BODY),
    template: z.enum(['concept', 'project', 'decision', 'freeform']).optional(),
    tags: z.array(z.string().min(1).max(32)).max(MAX_TAGS).optional(),
    related: z.array(z.string().min(1).max(200)).max(MAX_RELATED).optional(),
    mode: z.enum(['create', 'append', 'merge']).optional(),
    source_session: z.string().max(128).optional(),
  },
};

export async function handleWriteWiki(vault, args) {
  validate(args);
  const path = args.path;
  // MASK_RULES를 title / body / tags 모두에 적용 (Desktop에서 실수로 붙여넣은
  // 비밀이 frontmatter / heading / 본문 어디에도 남지 않도록 한다).
  // related[]는 다른 페이지에 대한 링크 키로 사용되므로, 마스크하면
  // wikilink가 깨진다. 비밀을 related에 넣는 유스케이스 자체가 상정 외이며,
  // schema 200자 제한과 조합해 리스크를 억제한다.
  const title = applyMasks(String(args.title).trim());
  const body = applyMasks(String(args.body));
  const template = args.template ?? 'freeform';
  const tagsIn = Array.isArray(args.tags)
    ? dedupeStrings(args.tags).map(applyMasks)
    : [];
  const relatedIn = Array.isArray(args.related) ? dedupeStrings(args.related) : [];
  const mode = args.mode ?? 'create';
  const sourceSession = args.source_session ?? null;

  const abs = await assertInsideWiki(vault, path);

  return withLock(vault, async () => {
    let exists = false;
    try {
      const st = await stat(abs);
      exists = st.isFile();
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
    }

    if (mode === 'create' && exists) {
      const e = new Error(`file exists: ${path}`);
      e.code = 'file_exists';
      throw e;
    }

    const nowIso = new Date().toISOString();
    let templateData = { tags: [] };
    let templateBodyStub = '';
    if (template !== 'freeform') {
      const loaded = await loadTemplate(template);
      templateData = loaded.data ?? {};
      templateBodyStub = loaded.body ?? '';
    }

    const warnings = [];
    let action;
    let newContent;
    let existingContent = '';
    let existingFm = {};
    let existingBody = '';
    if (exists) {
      existingContent = await readFile(abs, 'utf8');
      const parsed = parseFrontmatter(existingContent);
      existingFm = parsed.data;
      existingBody = parsed.body;
    }

    if (mode === 'create' || !exists) {
      const fm = {
        title,
        tags: dedupeStrings([...(templateData.tags ?? []), ...tagsIn]),
        created: nowIso,
        updated: nowIso,
        source: 'mcp-write-wiki',
      };
      if (sourceSession) fm.source_session = sourceSession;
      const bodyForFile = template === 'freeform'
        ? `\n# ${title}\n\n${body.replace(/\s+$/, '')}\n`
        : composeFromTemplate(templateBodyStub, body);
      newContent = serializeFrontmatter(fm, bodyForFile);
      action = 'created';
    } else if (mode === 'append') {
      const updatedFm = mergeFrontmatter(existingFm, {
        updated: nowIso,
        source: 'mcp-write-wiki',
        ...(sourceSession ? { source_session: sourceSession } : {}),
      });
      const appendedBody = ensureTrailingNewline(existingBody) +
        `\n## ${nowIso}\n\n${body.replace(/\s+$/, '')}\n`;
      newContent = serializeFrontmatter(updatedFm, appendedBody);
      action = 'appended';
    } else if (mode === 'merge') {
      const updatedFm = mergeFrontmatter(existingFm, {
        tags: dedupeStrings([...(existingFm.tags ?? []), ...(templateData.tags ?? []), ...tagsIn]),
        updated: nowIso,
        source: 'mcp-write-wiki',
        ...(sourceSession ? { source_session: sourceSession } : {}),
      });
      const appendedBody = ensureTrailingNewline(existingBody) +
        `\n## ${nowIso}\n\n${body.replace(/\s+$/, '')}\n`;
      newContent = serializeFrontmatter(updatedFm, appendedBody);
      action = 'merged';
    } else {
      const e = new Error(`unknown mode: ${mode}`);
      e.code = 'invalid_params';
      throw e;
    }

    await mkdir(dirname(abs), { recursive: true, mode: 0o700 });
    await atomicWrite(abs, newContent);

    // related[]의 링크 추가 기록 (best-effort)
    if (relatedIn.length > 0) {
      const wikiAbs = await realpath(join(vault, 'wiki'));
      const titleIndex = await buildTitleIndex(wikiAbs);
      for (const target of relatedIn) {
        const targetAbs = titleIndex.get(target);
        if (!targetAbs) {
          warnings.push(`related target not found: ${target}`);
          continue;
        }
        if (targetAbs === abs) continue;
        try {
          const cur = await readFile(targetAbs, 'utf8');
          const updated = appendRelatedLink(cur, title);
          if (updated !== cur) {
            await atomicWrite(targetAbs, updated);
          }
        } catch (err) {
          warnings.push(`failed to update ${relative(wikiAbs, targetAbs)}: ${err.message}`);
        }
      }
    }

    return { path: `wiki/${path}`, action, warnings };
  });
}

function validate(args) {
  if (!args || typeof args !== 'object') {
    const e = new Error('args must be an object');
    e.code = 'invalid_params';
    throw e;
  }
  for (const k of ['path', 'title', 'body']) {
    if (typeof args[k] !== 'string' || !args[k].trim()) {
      const e = new Error(`${k} is required`);
      e.code = 'invalid_params';
      throw e;
    }
  }
  if (args.template && !VALID_TEMPLATES.has(args.template) && args.template !== 'freeform') {
    const e = new Error('invalid template');
    e.code = 'invalid_params';
    throw e;
  }
  if (args.mode && !['create', 'append', 'merge'].includes(args.mode)) {
    const e = new Error('invalid mode');
    e.code = 'invalid_params';
    throw e;
  }
}

function composeFromTemplate(templateBody, userBody) {
  // 템플릿 최초의 "## <heading>" 바로 아래에 user body를 끼워 넣는다.
  // heading이 발견되지 않는 경우에는 말미에 추가.
  const lines = templateBody.split('\n');
  const insertAt = lines.findIndex((l, i) => /^##\s+/.test(l) && i < lines.length);
  if (insertAt === -1) {
    return `${ensureTrailingNewline(templateBody)}\n${userBody.replace(/\s+$/, '')}\n`;
  }
  const head = lines.slice(0, insertAt + 1).join('\n');
  const tail = lines.slice(insertAt + 1).join('\n');
  return `${head}\n\n${userBody.replace(/\s+$/, '')}\n${tail.startsWith('\n') ? tail : '\n' + tail}`;
}

async function buildTitleIndex(wikiAbs) {
  const index = new Map();
  const exclude = new Set(['.obsidian', '.archive', '.trash', 'templates']);
  async function walk(dir) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const dirent of entries) {
      if (exclude.has(dirent.name)) continue;
      if (dirent.name.startsWith('.')) continue;
      const childAbs = join(dir, dirent.name);
      if (dirent.isDirectory()) {
        await walk(childAbs);
      } else if (dirent.isFile() && dirent.name.endsWith('.md')) {
        try {
          const head = (await readFile(childAbs, 'utf8')).slice(0, 4096);
          const { data } = parseFrontmatter(head);
          if (typeof data.title === 'string' && data.title) {
            index.set(data.title, childAbs);
          }
          // 파일명 (확장자 없음)도 키로 사용
          const stem = basename(dirent.name, '.md');
          if (!index.has(stem)) index.set(stem, childAbs);
        } catch {
          // skip
        }
      }
    }
  }
  await walk(wikiAbs);
  return index;
}

async function atomicWrite(absPath, content) {
  const tmp = `${absPath}.tmp.${process.pid}.${Date.now()}`;
  const handle = await open(tmp, 'wx', 0o600);
  try {
    await handle.writeFile(content, 'utf8');
  } finally {
    await handle.close();
  }
  await rename(tmp, absPath);
}

function ensureTrailingNewline(s) {
  if (!s) return '';
  return s.endsWith('\n') ? s : s + '\n';
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
  }
  return out;
}
