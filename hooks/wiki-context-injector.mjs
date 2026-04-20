// wiki-context-injector.mjs — SessionStart 에서 wiki/index.md 를 additionalContext 로 주입한다
//
// Claude Code 는 훅의 stdout 에 JSON (`{ "additionalContext": "..." }`) 이 흘러오면
// 그 내용을 시스템 프롬프트에 추가한다. 본 스크립트는 wiki/index.md 를 읽어
// Karpathy LLM Wiki 패턴에 따라 "작업 전에 관련 페이지를 Read 하라"는
// 참조 규칙과 함께 프로젝트 정보 및 wiki 경로를 정돈해 출력한다.
//
// 설계 원칙 (session-logger.mjs 와 공통):
//   - Node 18+ 내장 모듈만 (`fs/promises`, `path`)
//   - 항상 exit 0 (페일세이프)
//   - OBSIDIAN_VAULT 미설정 / index.md 부재 / 읽기 실패 → 아무것도 출력하지 않고 exit 0
//
// 참고: tools/claude-brain/plan/26041502_참조방식을_Karpathy에_맞춘_형태로_수정.md

import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

// 모든 에러를 exit 0 으로 떨어뜨리는 세이프티 넷
process.on('uncaughtException', () => process.exit(0));
process.on('unhandledRejection', () => process.exit(0));

async function main() {
  const vault = process.env.OBSIDIAN_VAULT;
  if (!vault) return;

  const indexPath = join(vault, 'wiki', 'index.md');
  const index = await readFile(indexPath, 'utf-8').catch(() => null);
  if (index === null) return;

  // 프로젝트 이름은 cwd 의 말단 디렉터리에서 추정 (완전히 일치시킬 필요는 없다)
  const cwd = process.cwd();
  const projectName = cwd.split('/').filter(Boolean).pop() || 'unknown';

  const context = [
    '## 지식 베이스 (자동 주입)',
    '',
    '당신에게는 과거 작업에서 축적된 지식 베이스 (wiki) 가 있습니다.',
    '',
    '### 규칙',
    '- 작업을 시작하기 전에, 아래 목차에서 현재 작업과 관련 있어 보이는 페이지를 찾아내세요',
    '- 관련이 있어 보이는 페이지가 있다면 반드시 Read 도구로 읽은 뒤 작업을 시작하세요',
    '- 해당하는 페이지가 없다면 그대로 작업을 시작하세요',
    '- 작업 중에 유용한 분석이나 비교를 생성한 경우 wiki/analyses/ 에 페이지로 저장하세요',
    '',
    `### 현재 프로젝트: ${projectName}`,
    `### wiki 경로: $OBSIDIAN_VAULT/wiki/`,
    '',
    '### wiki 목차',
    index,
  ].join('\n');

  const output = JSON.stringify({ additionalContext: context });
  process.stdout.write(output);
}

main().catch(() => {
  // 만일을 대비한 이중 세이프티
  process.exit(0);
});
