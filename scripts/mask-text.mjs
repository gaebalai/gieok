#!/usr/bin/env node
// mask-text.mjs — 비밀 정보 마스킹과 source_type sanitize 의 얇은 CLI / 모듈 래퍼.
//
// CLI 모드:
//   cat in.txt | node scripts/mask-text.mjs > out.txt
//   node scripts/mask-text.mjs --sanitize-source-type "; rm -rf /"
//
// 모듈 모드:
//   import { maskText, sanitizeSourceType } from './mask-text.mjs';
//
// extract-pdf.sh 는 pdftotext 의 표준 출력을 본 CLI 에 파이프하여 마스크 적용 후의
// 텍스트를 chunk MD 로 기록한다. 실제 처리는 ./lib/masking.mjs 가 담당하며,
// 본 파일은 stdio 의 I/O 와 entry point 판정만 담당한다.
//
// 설계서: tools/claude-brain/plan/claude/26041705_document-ingest-design.md §4.5

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { MASK_RULES, maskText, sanitizeSourceType } from './lib/masking.mjs';

export { MASK_RULES, maskText, sanitizeSourceType };

function isMainEntry() {
  if (!process.argv[1]) return false;
  try {
    return fileURLToPath(import.meta.url) === process.argv[1];
  } catch {
    return false;
  }
}

function runCli(argv) {
  const args = argv.slice(2);
  if (args.length >= 2 && args[0] === '--sanitize-source-type') {
    process.stdout.write(sanitizeSourceType(args[1]));
    process.stdout.write('\n');
    return 0;
  }
  const raw = readFileSync(0, 'utf8');
  process.stdout.write(maskText(raw));
  return 0;
}

if (isMainEntry()) {
  try {
    process.exit(runCli(process.argv));
  } catch (err) {
    process.stderr.write(`mask-text: ${err?.message || err}\n`);
    process.exit(1);
  }
}
