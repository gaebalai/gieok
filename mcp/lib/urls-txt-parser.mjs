// urls-txt-parser.mjs — raw-sources/<subdir>/urls.txt 의 행을 파싱
//
// 형식:
//   URL [; key=value [; key=value ...]]
//   # 주석 (행 전체, 또는 행 도중의 ' #' 이후)
//
// 지원 key:
//   tags          — 쉼표 구분 태그
//   title         — 타이틀 덮어쓰기
//   source_type   — 기사 종별 (article / paper / etc.)
//   refresh_days  — 정수 (1..3650) 또는 "never"
//
// 설계서 §4.6: per-URL refresh_days 로 Wiki 마다 재취득 빈도를 제어한다.

const ALLOWED_KEYS = new Set(['tags', 'title', 'source_type', 'refresh_days']);
const REFRESH_DAYS_MIN = 1;
const REFRESH_DAYS_MAX = 3650; // 10 년

/**
 * @param {string} text
 * @returns {{entries: Array<{url: string, meta: object, lineNo: number}>, warnings: string[]}}
 */
export function parseUrlsTxt(text) {
  const entries = [];
  const warnings = [];
  if (typeof text !== 'string') return { entries, warnings };
  const lines = text.split(/\r?\n/);
  let lineNo = 0;
  for (const raw of lines) {
    lineNo += 1;
    // 주석 제거 — 행두의 # 와, 공백 직후의 # 만을 감지 (URL 내의 #fragment 는 보존).
    const line = stripInlineComment(raw).trim();
    if (!line) continue;
    const segments = line.split(';').map((s) => s.trim());
    const urlPart = segments[0];
    if (!/^https?:\/\//.test(urlPart)) {
      warnings.push(`line ${lineNo}: not a URL: ${urlPart}`);
      continue;
    }
    const meta = {};
    for (let i = 1; i < segments.length; i++) {
      const kv = segments[i];
      if (!kv) continue;
      const eqIdx = kv.indexOf('=');
      if (eqIdx === -1) {
        warnings.push(`line ${lineNo}: malformed DSL (no "="): ${kv}`);
        continue;
      }
      const key = kv.slice(0, eqIdx).trim();
      const val = kv.slice(eqIdx + 1).trim();
      if (!ALLOWED_KEYS.has(key)) {
        warnings.push(`line ${lineNo}: unknown DSL key: ${key}`);
        continue;
      }
      if (key === 'tags') {
        meta.tags = val.split(',').map((t) => t.trim()).filter(Boolean);
      } else if (key === 'refresh_days') {
        if (val === 'never') {
          meta.refresh_days = 'never';
        } else {
          const n = Number(val);
          if (Number.isInteger(n) && n >= REFRESH_DAYS_MIN && n <= REFRESH_DAYS_MAX) {
            meta.refresh_days = n;
          } else {
            warnings.push(
              `line ${lineNo}: invalid refresh_days value: ${val} (expected "never" or int ${REFRESH_DAYS_MIN}-${REFRESH_DAYS_MAX})`,
            );
          }
        }
      } else {
        meta[key] = val;
      }
    }
    entries.push({ url: urlPart, meta, lineNo });
  }
  return { entries, warnings };
}

/**
 * URL fragment (#) 와 주석 (#) 을 구별하기 위해, 행두 # 또는 공백 직후 # 만 주석 취급.
 * 행의 선두가 # → 통째로 주석. 그 외에 처음 발견되는 ' #' 의 앞까지 유효.
 */
function stripInlineComment(line) {
  const trimmed = line.trimStart();
  if (trimmed.startsWith('#')) return '';
  const idx = line.indexOf(' #');
  return idx === -1 ? line : line.slice(0, idx);
}
