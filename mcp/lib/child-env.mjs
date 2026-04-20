// child-env.mjs — MCP 자식 프로세스용 환경변수 allowlist (2026-04-20 신설)
//
// 2026-04-20 security-review HIGH-d1 fix:
//   기존 구현은 `ENV_ALLOW_PREFIXES = ['GIEOK_', ...]` 와 같이 `GIEOK_` 프리픽스를
//   통째로 허용했기 때문에, 테스트 / 운영 용도의 다음 env 가 MCP 자식 프로세스로
//   propagate 되고 있었다 (production leak → 다층 방어 붕괴):
//     - GIEOK_URL_ALLOW_LOOPBACK (SSRF 최종 방어선)
//     - GIEOK_URL_IGNORE_ROBOTS (robots bypass)
//     - GIEOK_EXTRACT_URL_SCRIPT / GIEOK_ALLOW_EXTRACT_URL_OVERRIDE (임의 bash 경로)
//     - GIEOK_URL_MAX_* / GIEOK_URL_USER_AGENT 등 (부모 process 에서만 유효한 설정)
//
//   본 모듈에서는 **exact-match allowlist** 로 전환하여, propagate 가 필요한
//   것만 명시적으로 나열한다. 자식 측에서 재평가되어야 할 security env 는 의도적으로
//   누락시킨다 (자식의 URL fetch / robots check 는 현재 경로상에서는 일어나지 않지만,
//   향후 chain 확장 시 bypass 를 상속하지 않도록 하는 defense-in-depth).
//
//   MED-d2 fix: 기존 `ingest-pdf.mjs` 와 `llm-fallback.mjs` 에서 동일 로직을 개별
//   관리하던 drift 를 공통 모듈로 통합. ingest-pdf / llm-fallback 양쪽이
//   본 모듈을 import 하면 allowlist 변경을 1 곳에서 반영할 수 있다.

/**
 * 완전 일치로 자식에 propagate 하는 환경변수 (상시).
 *
 * - OS 표준: PATH, HOME, USER 등 (claude CLI / shell 이 필요로 함)
 * - Node: TMPDIR, NODE_PATH, NODE_OPTIONS
 * - 본 MCP 서버용: OBSIDIAN_VAULT (자식 claude 가 Vault 인식에 사용)
 * - GIEOK_ 내부 통신 플래그:
 *    - GIEOK_NO_LOG       : Hook 재귀 억제
 *    - GIEOK_MCP_CHILD    : 자식 프로세스에서의 부모 WARN 억제 판정
 *    - GIEOK_DEBUG        : 디버그 출력
 *    - GIEOK_LLM_FB_OUT   : LLM 폴백이 결과를 쓰는 절대 경로
 *    - GIEOK_LLM_FB_LOG   : LLM 폴백의 stderr 로그 경로
 *
 * 다음은 **의도적으로 exclude**:
 *    GIEOK_URL_ALLOW_LOOPBACK / GIEOK_URL_IGNORE_ROBOTS /
 *    GIEOK_URL_MAX_* / GIEOK_URL_USER_AGENT / GIEOK_URL_REFRESH_DAYS /
 *    GIEOK_EXTRACT_URL_SCRIPT / GIEOK_ALLOW_EXTRACT_URL_OVERRIDE /
 *    GIEOK_INGEST_MAX_SECONDS 등
 */
export const ENV_ALLOW_EXACT = new Set([
  // OS 표준
  'PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TERM', 'TZ',
  'LANG', 'LC_ALL', 'LC_CTYPE',
  // Node
  'TMPDIR', 'NODE_PATH', 'NODE_OPTIONS',
  // GIEOK 본체
  'OBSIDIAN_VAULT',
  // GIEOK 내부 통신 플래그 (자식 프로세스가 올바르게 동작하기 위해 필요)
  'GIEOK_NO_LOG',
  'GIEOK_MCP_CHILD',
  'GIEOK_DEBUG',
  'GIEOK_LLM_FB_OUT',
  'GIEOK_LLM_FB_LOG',
]);

/**
 * 프리픽스 일치로 자식에 propagate 하는 허용 리스트.
 *
 * - ANTHROPIC_ : claude CLI 의 API 키 / 설정 (ANTHROPIC_API_KEY 등)
 * - CLAUDE_    : claude CLI 의 설정 (CLAUDE_HOME, CLAUDE_CONFIG_DIR 등)
 * - XDG_       : XDG Base Directory (~/.config, ~/.cache 의 해결에 필요)
 *
 * `GIEOK_` 는 여기에서 **의도적으로 삭제**. GIEOK_ 는 exact-match allowlist 의
 * 내부 통신 플래그만 통과시킨다 (HIGH-d1 fix).
 */
export const ENV_ALLOW_PREFIXES = ['ANTHROPIC_', 'CLAUDE_', 'XDG_'];

/**
 * 부모 프로세스의 process.env 를 allowlist 로 필터링하고, extraEnv 를 덮어써 합성한다.
 *
 * @param {Record<string,string>} [extraEnv] - 자식에 추가로 넘기고 싶은 env (allowlist 무시하고 통과)
 * @returns {Record<string,string>} 자식 프로세스용 최소 env
 */
export function buildChildEnv(extraEnv = {}) {
  const out = {};
  for (const [key, val] of Object.entries(process.env)) {
    if (ENV_ALLOW_EXACT.has(key) || ENV_ALLOW_PREFIXES.some((p) => key.startsWith(p))) {
      out[key] = val;
    }
  }
  return { ...out, ...extraEnv };
}
