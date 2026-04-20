// env-helpers.mjs — MCP 서버 공통 환경변수 헬퍼
//
// 2026-04-20 기능 2.2 security review (blue M-1 + L-4 / open-issues #13) 대응:
//   - url-fetch / url-image / ingest-url 에서 중복되던 envPositiveInt 를 통합
//   - Number("") === 0 이나 Number("abc") === NaN 의 footgun 을 피하고,
//     양의 유한수만 수용하는 정책으로 cap / timeout / redirects 의
//     fail-open 무효화를 방지

/**
 * Read a positive integer environment variable, falling back to a safe default.
 *
 * Treats empty-string / "0" / negative / NaN as unset-and-default so that
 * an operator mis-configuring `GIEOK_URL_MAX_SIZE_BYTES=0` (intended to
 * disable) or `=foo` (typo) does not silently turn the cap off.
 *
 * @param {string} name Environment variable name
 * @param {number} fallback Default value when not set / invalid
 * @returns {number} positive finite number (may be non-integer, caller caps if needed)
 */
export function envPositiveInt(name, fallback) {
  const raw = process.env[name];
  if (!raw || raw.trim() === '') return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}
