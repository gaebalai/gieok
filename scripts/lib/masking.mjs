// masking.mjs — 부모 레포 내 비밀 정보 마스킹 규칙과 값 sanitize 의 공통 공급원.
//
// 이 ES 모듈은 아래에서 import 된다:
//   - hooks/session-logger.mjs           (session-logs/ 에 쓰기 시)
//   - scripts/mask-text.mjs              (extract-pdf.sh 의 파이프에서 쓰는 CLI)
//
// 독립 서브프로젝트 경계 관계로 mcp/lib/masking.mjs 는 동일 내용을 재선언하고 있으며,
// 완전 공통화는 설계서 26041705 §11.5 대로 별도 PR 의 과제로 남겨 두고 있다.
// 새 패턴을 추가할 때는 아래 3곳을 동기화할 것:
//   1. tools/claude-brain/scripts/lib/masking.mjs   (본 파일 / 부모 레포)
//   2. tools/claude-brain/mcp/lib/masking.mjs       (MCP 독립 프로젝트)
//   3. tools/claude-brain/scripts/scan-secrets.sh   (Bash 측 ERE 재표현)
//
// 순서 중요: 긴 프리픽스부터 먼저 매치시킨다.

export const MASK_RULES = [
  [/sk-ant-[A-Za-z0-9\-_]{20,}/g, 'sk-ant-***'],
  [/sk-proj-[A-Za-z0-9\-_]{20,}/g, 'sk-proj-***'],
  [/sk-[A-Za-z0-9]{20,}/g, 'sk-***'],
  [/ghp_[A-Za-z0-9]{20,}/g, 'ghp_***'],
  [/github_pat_[A-Za-z0-9_]{20,}/g, 'github_pat_***'],
  [/gho_[A-Za-z0-9]{20,}/g, 'gho_***'],
  [/ghu_[A-Za-z0-9]{20,}/g, 'ghu_***'],
  [/AIza[A-Za-z0-9\-_]{20,}/g, 'AIza***'],
  [/AKIA[A-Z0-9]{16}/g, 'AKIA***'],
  [/xox[baprs]-[A-Za-z0-9\-]{10,}/g, 'xox*-***'],
  [/vercel_[A-Za-z0-9\-_]{20,}/g, 'vercel_***'],
  [/npm_[A-Za-z0-9]{20,}/g, 'npm_***'],
  [/[spr]k_(live|test)_[A-Za-z0-9]{20,}/g, 'stripe_***'],
  [/sbp_[A-Za-z0-9]{20,}/g, 'sbp_***'],
  [/private_key_id["']?\s*[:=]\s*["']?[a-f0-9]{40}/gi, 'private_key_id=***'],
  [/(?:SharedAccessKey|AccountKey)\s*=\s*[A-Za-z0-9+/=]{20,}/g, 'AzureKey=***'],
  [/Bearer\s+[A-Za-z0-9\-._~+/=]+/g, 'Bearer ***'],
  [/(?:Basic|Digest)\s+[A-Za-z0-9+/=]{10,}/g, 'Authorization ***'],
  [/:\/\/[^:]+:[^@]+@/g, '://***:***@'],
  [
    /(password|passwd|secret|token|api[_\-]?key)\s*[:=]\s*["']?([^\s"'&]+)["']?/gi,
    '$1=***',
  ],
  [
    /-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]+?-----END [A-Z ]+PRIVATE KEY-----/g,
    '<PRIVATE KEY REDACTED>',
  ],
];

// pdftotext 추출 텍스트나 훅 입력에 대해 마스킹 룰을 적용한다.
// MASK_RULES 적용 전에 아래 Unicode 불가시/쓰기방향 제어 문자를 제거한 뒤
// NFC 정규화한다. 이유는 소프트 하이픈이나 ZWSP 가 ASCII 패턴을 분단하여
// 토큰 (sk-ant-*, ghp_*, AKIA*, Bearer *) 을 그냥 통과시키는 공격을 막기 위해서다.
// 참조: security-review/meeting/2026-04-17_feature-2-red-blue.md (VULN-002/003/014)
const INVISIBLE_CHARS_RE = /[\u00AD\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/gu;

export function maskText(text) {
  if (typeof text !== 'string') return text;
  let out = text.replace(INVISIBLE_CHARS_RE, '').normalize('NFC');
  for (const [re, repl] of MASK_RULES) {
    out = out.replace(re, repl);
  }
  return out;
}

// source_type 나 frontmatter 유래의 짧은 문자열을 YAML/셸에 안전히 떨어뜨리기 위한
// sanitize. 설계서 26041705 §4.2 의 규약에 따라 아래를 제거한다:
//   - 제어 문자 (U+0000~U+001F, U+007F)
//   - Unicode 불가시/쓰기방향 제어 문자 (ZWSP, RTLO, BOM, soft hyphen 등)
//   - 셸 메타 문자 (` $ ; & |)
// 출력은 NFC 정규화하여 호모글리프 공격의 1차 방어로 삼는다.
// 목적은 prompt injection 내성과 YAML/셸 정합성 보장뿐이며,
// 일반적인 기호 (영숫자 / 하이픈 / 언더스코어 / 공백 / 점 / 콜론) 은 통과시킨다.
export function sanitizeSourceType(value) {
  if (typeof value !== 'string') return '';
  return value
    .replace(/[\u0000-\u001F\u007F]/g, '')
    .replace(INVISIBLE_CHARS_RE, '')
    .replace(/[`$;&|]/g, '')
    .normalize('NFC')
    .trim();
}
