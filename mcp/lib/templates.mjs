// templates.mjs — wiki 노트용 템플릿 (concept / project / decision) 의 로드.
// templates/notes/*.md 를 frontmatter + body skeleton 으로 반환한다.

import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFrontmatter } from './frontmatter.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

// gieok-mcp 가 tools/claude-brain/mcp/lib/ 에 있으므로, 템플릿은 ../../templates/notes/
// 환경변수 GIEOK_TEMPLATES_DIR 로 덮어쓸 수 있음 (테스트용)
function resolveTemplatesDir() {
  if (process.env.GIEOK_TEMPLATES_DIR) {
    return process.env.GIEOK_TEMPLATES_DIR;
  }
  return join(__dirname, '..', '..', 'templates', 'notes');
}

export const VALID_TEMPLATES = new Set(['concept', 'project', 'decision']);

export async function loadTemplate(name) {
  if (!VALID_TEMPLATES.has(name)) {
    throw new Error(`unknown template: ${name}`);
  }
  const path = join(resolveTemplatesDir(), `${name}.md`);
  const content = await readFile(path, 'utf8');
  return parseFrontmatter(content);
}
