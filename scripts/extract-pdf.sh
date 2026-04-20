#!/usr/bin/env bash
#
# extract-pdf.sh — PDF 를 pdftotext 로 추출하고 고정 페이지 폭의 chunk Markdown 으로 기록한다.
#
# 사용법:
#   extract-pdf.sh <pdf-path> <output-dir> <subdir-prefix>
#
# 인자:
#   pdf-path        raw-sources/ 하위의 PDF (realpath 로 검증)
#   output-dir      chunk MD 를 기록할 위치 (보통 $OBSIDIAN_VAULT/.cache/extracted/)
#   subdir-prefix   chunk 파일명 접두사 (보통 raw-sources/ 의 서브디렉터리 이름)
#
# 출력 파일명:
#   <output-dir>/<subdir-prefix>-<stem>-pp<NNN>-<MMM>.md
#
# 환경 변수:
#   GIEOK_PDF_CHUNK_PAGES       기본 15. 1 chunk 의 페이지 폭
#   GIEOK_PDF_OVERLAP           기본 1. chunk 경계에서 중복되는 페이지 수 (0 이면 비활성)
#   GIEOK_PDF_MAX_SOFT_PAGES    기본 500. 초과 시 앞 500p 만 처리 + truncated: true
#   GIEOK_PDF_MAX_HARD_PAGES    기본 1000. 초과 시 완전 스킵 (exit 4)
#   GIEOK_PDF_LAYOUT            기본 0. 1 이면 pdftotext 에 -layout 부여 (표 유지)
#   GIEOK_PDF_PAGE_TIMEOUT      기본 300. 1 chunk 당 pdftotext 타임아웃 (초)
#
# 종료 코드:
#   0  정상 종료 (chunk 생성 or 멱등 스킵)
#   1  실행 환경 부족 (pdfinfo / pdftotext / node 가 PATH 에 없음)
#   2  PDF 가 존재하지 않음 / 암호화됨 / pdfinfo 호출 실패
#   3  모든 chunk 가 빈 텍스트 (스캔 이미지 PDF 일 가능성)
#   4  페이지 수가 MAX_HARD_PAGES 초과
#   5  PDF 가 raw-sources/ 하위가 아님 (경로 탐색 방어)
#   6  pdfinfo 의 Pages 필드가 부정확
#   64 인자 개수가 잘못됨
#
# 설계서: tools/claude-brain/plan/claude/26041705_document-ingest-design.md §4.1
# 회의록: tools/claude-brain/plan/claude/26041706_meeting_document-ingest-design-review.md

set -euo pipefail
umask 077

LOG_PREFIX="[extract-pdf]"

# -----------------------------------------------------------------------------
# 설정
# -----------------------------------------------------------------------------

CHUNK_PAGES="${GIEOK_PDF_CHUNK_PAGES:-15}"
OVERLAP="${GIEOK_PDF_OVERLAP:-1}"
MAX_SOFT="${GIEOK_PDF_MAX_SOFT_PAGES:-500}"
MAX_HARD="${GIEOK_PDF_MAX_HARD_PAGES:-1000}"
LAYOUT_DEFAULT="${GIEOK_PDF_LAYOUT:-0}"
PAGE_TIMEOUT="${GIEOK_PDF_PAGE_TIMEOUT:-300}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MASK_SCRIPT="${SCRIPT_DIR}/mask-text.mjs"

# -----------------------------------------------------------------------------
# 인자 검증
# -----------------------------------------------------------------------------

if [[ $# -ne 3 ]]; then
  echo "${LOG_PREFIX} usage: extract-pdf.sh <pdf-path> <output-dir> <subdir-prefix>" >&2
  exit 64
fi

PDF_PATH="$1"
OUTPUT_DIR="$2"
SUBDIR_PREFIX="$3"

if [[ ! -f "${PDF_PATH}" ]]; then
  echo "${LOG_PREFIX} ERROR: PDF not found: ${PDF_PATH}" >&2
  exit 2
fi

# realpath 로 경로 탐색 방어: $OBSIDIAN_VAULT/raw-sources/ 하위만 허용.
# VULN-011 대책: substring `*/raw-sources/*` 가 아니라 Vault 로부터의 prefix match 로
# 강화한다. OBSIDIAN_VAULT 가 미설정일 때는 하위 호환을 위해 substring 판정으로 되돌린다.
PDF_REAL="$(realpath "${PDF_PATH}")"
if [[ -n "${OBSIDIAN_VAULT:-}" ]]; then
  VAULT_REAL="$(realpath "${OBSIDIAN_VAULT}" 2>/dev/null || echo "${OBSIDIAN_VAULT}")"
  if [[ "${PDF_REAL}" != "${VAULT_REAL}/raw-sources/"* ]]; then
    echo "${LOG_PREFIX} ERROR: PDF not under \${OBSIDIAN_VAULT}/raw-sources/: ${PDF_REAL}" >&2
    exit 5
  fi
elif [[ "${PDF_REAL}" != */raw-sources/* ]]; then
  echo "${LOG_PREFIX} ERROR: PDF is not under raw-sources/: ${PDF_REAL}" >&2
  exit 5
fi

# -----------------------------------------------------------------------------
# 의존성 확인
# -----------------------------------------------------------------------------

for bin in pdfinfo pdftotext node; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "${LOG_PREFIX} ERROR: ${bin} not found in PATH" >&2
    if [[ "${bin}" == "pdfinfo" || "${bin}" == "pdftotext" ]]; then
      echo "${LOG_PREFIX}        install poppler: brew install poppler | apt install poppler-utils" >&2
    fi
    exit 1
  fi
done

# GNU timeout 탐색: macOS 기본에 `timeout` 이 없으므로 gtimeout (brew coreutils)
# 을 차선으로 두고, 둘 다 없으면 빈 배열로 타임아웃 없이 동작시킨다.
# DoS 가드는 auto-ingest.sh 쪽의 30분 소프트 타임아웃과 MAX_HARD_PAGES=1000 이 주축이며,
# 여기서의 타임아웃은 이중 방어.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${PAGE_TIMEOUT}")
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(gtimeout "${PAGE_TIMEOUT}")
else
  TIMEOUT_CMD=()
  echo "${LOG_PREFIX} WARN: neither 'timeout' nor 'gtimeout' found; pdftotext will run without per-chunk timeout" >&2
fi

if [[ ! -f "${MASK_SCRIPT}" ]]; then
  echo "${LOG_PREFIX} ERROR: mask-text.mjs not found: ${MASK_SCRIPT}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# pdfinfo 로 메타데이터 및 전제 체크
# -----------------------------------------------------------------------------

INFO="$(pdfinfo "${PDF_PATH}" 2>/dev/null || true)"
if [[ -z "${INFO}" ]]; then
  echo "${LOG_PREFIX} ERROR: pdfinfo failed for: ${PDF_REAL}" >&2
  exit 2
fi

if echo "${INFO}" | grep -qE '^Encrypted:[[:space:]]+yes'; then
  echo "${LOG_PREFIX} ERROR: Encrypted PDF, skipping: ${PDF_REAL}" >&2
  exit 2
fi

PAGES="$(echo "${INFO}" | awk -F':[[:space:]]+' '/^Pages:/ {print $2; exit}')"
if [[ -z "${PAGES}" || ! "${PAGES}" =~ ^[0-9]+$ ]]; then
  echo "${LOG_PREFIX} ERROR: pdfinfo Pages field missing or invalid: '${PAGES}'" >&2
  exit 6
fi

if (( PAGES > MAX_HARD )); then
  echo "${LOG_PREFIX} ERROR: PDF has ${PAGES} pages (> hard limit ${MAX_HARD}), skipping: ${PDF_REAL}" >&2
  exit 4
fi

# 기능 2.1: PDF 전체의 sha256 을 계산하여 chunk MD 의 frontmatter 에 기록한다.
# VULN-006/018 완전판: mtime 기반 멱등 판정으로는 chunk MD / summary MD 의
# 내용 교체를 감지할 수 없으므로 sha256 기반 비교로 이행한다 (auto-ingest.sh 측).
# shasum 우선 (macOS 기본), sha256sum 을 폴백 (GNU coreutils / Alpine).
if command -v shasum >/dev/null 2>&1; then
  PDF_SHA256="$(shasum -a 256 "${PDF_PATH}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  PDF_SHA256="$(sha256sum "${PDF_PATH}" | awk '{print $1}')"
else
  echo "${LOG_PREFIX} ERROR: neither shasum nor sha256sum in PATH" >&2
  exit 1
fi
if [[ -z "${PDF_SHA256}" || ! "${PDF_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "${LOG_PREFIX} ERROR: sha256 calculation failed for: ${PDF_REAL}" >&2
  exit 1
fi

TRUNCATED=false
EFFECTIVE_PAGES="${PAGES}"
if (( PAGES > MAX_SOFT )); then
  echo "${LOG_PREFIX} WARN: PDF has ${PAGES} pages (> soft limit ${MAX_SOFT}), truncating to first ${MAX_SOFT}: ${PDF_REAL}" >&2
  TRUNCATED=true
  EFFECTIVE_PAGES="${MAX_SOFT}"
fi

RAW_TITLE="$(echo "${INFO}" | awk -F':[[:space:]]+' '/^Title:/ {sub(/^Title:[[:space:]]+/, ""); print; exit}')"
RAW_AUTHOR="$(echo "${INFO}" | awk -F':[[:space:]]+' '/^Author:/ {sub(/^Author:[[:space:]]+/, ""); print; exit}')"
RAW_CREATION="$(echo "${INFO}" | awk -F':[[:space:]]+' '/^CreationDate:/ {sub(/^CreationDate:[[:space:]]+/, ""); print; exit}')"

PDF_STEM="$(basename "${PDF_PATH}" .pdf)"

# pdfinfo Title 이 "Microsoft Word - ..." 같은 쓰레기 패턴이면 버리고 파일명으로 폴백
title_is_junk() {
  local t="$1"
  [[ -z "${t}" ]] && return 0
  if [[ "${t}" =~ ^Microsoft[[:space:]]Word([[:space:]]-.*)?$ ]]; then return 0; fi
  if [[ "${t}" =~ ^Untitled$ ]]; then return 0; fi
  if [[ "${t}" == "." ]]; then return 0; fi
  if [[ "${t}" =~ ^Document[0-9]*$ ]]; then return 0; fi
  return 1
}

if title_is_junk "${RAW_TITLE}"; then
  TITLE="${PDF_STEM}"
else
  TITLE="${RAW_TITLE}"
fi

# -----------------------------------------------------------------------------
# 사이드카 .meta.yaml (임의) 간이 파싱
# -----------------------------------------------------------------------------

SIDECAR="${PDF_PATH%.pdf}.meta.yaml"
SIDECAR_SOURCE_TYPE=""
SIDECAR_TITLE=""
SIDECAR_AUTHORS=""
SIDECAR_YEAR=""
SIDECAR_URL=""
LAYOUT_FLAG="${LAYOUT_DEFAULT}"

strip_quotes() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "${v}" =~ ^\"(.*)\"$ ]]; then v="${BASH_REMATCH[1]}"; fi
  if [[ "${v}" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
  printf '%s' "${v}"
}

if [[ -f "${SIDECAR}" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # 주석 / 빈 줄 / 선두 리스트 기호 무시
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    # key: value 의 단순 스칼라만 지원 (네스트・리스트는 미지원)
    if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      raw="${BASH_REMATCH[2]}"
      val="$(strip_quotes "${raw}")"
      case "${key}" in
        source_type) SIDECAR_SOURCE_TYPE="${val}" ;;
        title) SIDECAR_TITLE="${val}" ;;
        authors) SIDECAR_AUTHORS="${val}" ;;
        year) SIDECAR_YEAR="${val}" ;;
        url) SIDECAR_URL="${val}" ;;
        extract_layout)
          # bash 3.2 호환: ${val,,} 를 쓸 수 없으므로 tr 로 소문자화
          lc_val="$(printf '%s' "${val}" | tr '[:upper:]' '[:lower:]')"
          if [[ "${lc_val}" == "true" || "${val}" == "1" ]]; then
            LAYOUT_FLAG=1
          else
            LAYOUT_FLAG=0
          fi
          ;;
      esac
    fi
  done < "${SIDECAR}"
fi

if [[ -n "${SIDECAR_TITLE}" ]]; then
  TITLE="${SIDECAR_TITLE}"
fi

# source_type: 사이드카 > 서브디렉터리 이름 폴백. sanitize 강제.
SOURCE_TYPE_RAW="${SIDECAR_SOURCE_TYPE:-${SUBDIR_PREFIX}}"
SOURCE_TYPE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${SOURCE_TYPE_RAW}")"
[[ -z "${SOURCE_TYPE}" ]] && SOURCE_TYPE="unknown"

# 타이틀 등에서도 제어 문자를 제거 (YAML 깨짐 방지)
TITLE_SAFE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${TITLE}")"
[[ -z "${TITLE_SAFE}" ]] && TITLE_SAFE="${PDF_STEM}"
AUTHOR_SAFE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${RAW_AUTHOR}")"
URL_SAFE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${SIDECAR_URL}")"
AUTHORS_SAFE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${SIDECAR_AUTHORS}")"
YEAR_SAFE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${SIDECAR_YEAR}")"
# VULN-001 대책: pdfinfo 의 CreationDate 에도 sanitize 를 강제한다 (개행/제어 문자에 의한
# YAML frontmatter 파괴와 Unicode 불가시 문자 경유 prompt injection 방지).
CREATION_SAFE="$(node "${MASK_SCRIPT}" --sanitize-source-type "${RAW_CREATION}")"

# -----------------------------------------------------------------------------
# 출력 디렉터리 준비
# -----------------------------------------------------------------------------

mkdir -p "${OUTPUT_DIR}"
chmod 0700 "${OUTPUT_DIR}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Chunk 경계 계산
# -----------------------------------------------------------------------------
# 규약 (설계서 §4.4):
#   chunk 0 은 [1, min(CHUNK_PAGES, EFFECTIVE_PAGES)]
#   chunk i (i≥1) 는 [block_start_i - overlap, min(block_start_i + CHUNK_PAGES - 1, EFFECTIVE_PAGES)]
#   block_start_i = 1 + i * CHUNK_PAGES
#   마지막 chunk 의 신규 페이지 (last - prev_last) 가 CHUNK_PAGES/3 이하이면 직전 chunk 에 통합
# 비분할 임계값: EFFECTIVE_PAGES <= CHUNK_PAGES 일 때 1 chunk 로 [1, EFFECTIVE_PAGES] 출력

declare -a CHUNK_FIRSTS=()
declare -a CHUNK_LASTS=()

if (( EFFECTIVE_PAGES <= CHUNK_PAGES )); then
  CHUNK_FIRSTS+=(1)
  CHUNK_LASTS+=("${EFFECTIVE_PAGES}")
else
  i=0
  while :; do
    block_start=$(( 1 + i * CHUNK_PAGES ))
    (( block_start > EFFECTIVE_PAGES )) && break
    if (( i == 0 )); then
      first=1
    else
      first=$(( block_start - OVERLAP ))
      (( first < 1 )) && first=1
    fi
    last=$(( block_start + CHUNK_PAGES - 1 ))
    (( last > EFFECTIVE_PAGES )) && last="${EFFECTIVE_PAGES}"
    CHUNK_FIRSTS+=("${first}")
    CHUNK_LASTS+=("${last}")
    (( last >= EFFECTIVE_PAGES )) && break
    i=$(( i + 1 ))
  done

  # 최종 chunk 통합 판정
  n="${#CHUNK_FIRSTS[@]}"
  if (( n >= 2 )); then
    merge_threshold=$(( CHUNK_PAGES / 3 ))
    (( merge_threshold < 1 )) && merge_threshold=1
    last_prev="${CHUNK_LASTS[$(( n - 2 ))]}"
    last_cur="${CHUNK_LASTS[$(( n - 1 ))]}"
    unique_new=$(( last_cur - last_prev ))
    if (( unique_new <= merge_threshold )); then
      CHUNK_LASTS[$(( n - 2 ))]="${last_cur}"
      unset 'CHUNK_FIRSTS[n-1]'
      unset 'CHUNK_LASTS[n-1]'
      CHUNK_FIRSTS=("${CHUNK_FIRSTS[@]}")
      CHUNK_LASTS=("${CHUNK_LASTS[@]}")
    fi
  fi
fi

CHUNK_COUNT="${#CHUNK_FIRSTS[@]}"

# -----------------------------------------------------------------------------
# 멱등성: PDF mtime 보다 모든 chunk MD 가 더 새로우면 아무것도 하지 않는다
# -----------------------------------------------------------------------------

pdf_mtime="$(stat -f '%m' "${PDF_PATH}" 2>/dev/null || stat -c '%Y' "${PDF_PATH}" 2>/dev/null || echo 0)"
all_cached=true
declare -a CHUNK_PATHS=()
for (( i = 0; i < CHUNK_COUNT; i++ )); do
  first="${CHUNK_FIRSTS[$i]}"
  last="${CHUNK_LASTS[$i]}"
  # 기능 2.1 (VULN-005): 이중 하이픈 경계로 subdir/stem 충돌을 해소.
  # 구 명명 `<subdir>-<stem>-pp*.md` 는 auto-ingest.sh 쪽에서 호환으로 다루다가 90일 GC 로 소멸시킨다.
  fname="$(printf '%s--%s-pp%03d-%03d.md' "${SUBDIR_PREFIX}" "${PDF_STEM}" "${first}" "${last}")"
  path="${OUTPUT_DIR}/${fname}"
  CHUNK_PATHS+=("${path}")
  if [[ ! -f "${path}" ]]; then
    all_cached=false
  else
    chunk_mtime="$(stat -f '%m' "${path}" 2>/dev/null || stat -c '%Y' "${path}" 2>/dev/null || echo 0)"
    if (( chunk_mtime < pdf_mtime )); then
      all_cached=false
    fi
  fi
done

if [[ "${all_cached}" == "true" ]] && (( CHUNK_COUNT > 0 )); then
  echo "${LOG_PREFIX} Skip (all chunks up-to-date): ${PDF_REAL}"
  exit 0
fi

# -----------------------------------------------------------------------------
# chunk 마다 pdftotext + mask 로 텍스트 추출
# -----------------------------------------------------------------------------

escape_yaml() {
  # Escape double quotes for YAML double-quoted scalar
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

layout_arg=()
if [[ "${LAYOUT_FLAG}" == "1" ]]; then
  layout_arg=(-layout)
fi

all_empty=true
for (( i = 0; i < CHUNK_COUNT; i++ )); do
  first="${CHUNK_FIRSTS[$i]}"
  last="${CHUNK_LASTS[$i]}"
  out="${CHUNK_PATHS[$i]}"

  # pdftotext 로 텍스트 추출 (찾을 수 있으면 5분 타임아웃) → mask-text.mjs 로 마스킹.
  # bash 3.2 + set -u 하에서 빈 배열을 전개할 수 없으므로 ${arr[@]+...} 관용구를 사용.
  extracted="$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} pdftotext \
      -f "${first}" -l "${last}" -enc UTF-8 \
      ${layout_arg[@]+"${layout_arg[@]}"} \
      "${PDF_PATH}" - 2>/dev/null | node "${MASK_SCRIPT}" || true)"

  # 공백만인지 (trim 후 0 문자) 판정
  trimmed="$(printf '%s' "${extracted}" | tr -d '[:space:]')"
  if [[ -n "${trimmed}" ]]; then
    all_empty=false
  fi

  # frontmatter 생성
  tmp="$(mktemp "${out}.XXXXXX")"
  {
    echo "---"
    echo "title: \"$(escape_yaml "${TITLE_SAFE}")\""
    echo "source_type: \"$(escape_yaml "${SOURCE_TYPE}")\""
    echo "source_path: \"$(escape_yaml "${PDF_REAL}")\""
    echo "source_sha256: \"${PDF_SHA256}\""
    echo "page_range: \"$(printf '%03d-%03d' "${first}" "${last}")\""
    echo "page_first: ${first}"
    echo "page_last: ${last}"
    echo "total_pages: ${PAGES}"
    echo "chunks: ${CHUNK_COUNT}"
    if [[ "${TRUNCATED}" == "true" ]]; then
      echo "truncated: true"
      echo "effective_pages: ${EFFECTIVE_PAGES}"
    fi
    if [[ -n "${AUTHOR_SAFE}" ]]; then
      echo "author: \"$(escape_yaml "${AUTHOR_SAFE}")\""
    fi
    if [[ -n "${AUTHORS_SAFE}" ]]; then
      echo "authors: \"$(escape_yaml "${AUTHORS_SAFE}")\""
    fi
    if [[ -n "${YEAR_SAFE}" ]]; then
      echo "year: \"$(escape_yaml "${YEAR_SAFE}")\""
    fi
    if [[ -n "${URL_SAFE}" ]]; then
      echo "url: \"$(escape_yaml "${URL_SAFE}")\""
    fi
    if [[ -n "${CREATION_SAFE}" ]]; then
      echo "pdf_creation_date: \"$(escape_yaml "${CREATION_SAFE}")\""
    fi
    echo "extracted_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    echo "extractor: \"pdftotext$([[ ${LAYOUT_FLAG} == 1 ]] && echo ' -layout' || true)\""
    echo "---"
    echo ""
    echo "${extracted}"
  } > "${tmp}"
  chmod 0600 "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${out}"
done

if [[ "${all_empty}" == "true" ]]; then
  echo "${LOG_PREFIX} WARN: All chunks are empty (likely scanned image PDF): ${PDF_REAL}" >&2
  # VULN-007 대책: frontmatter 만 있는 빈 chunk MD 를 삭제한다. 남겨 두면 auto-ingest.sh 의
  # .cache/extracted/ 카운트에 잡혀, 본문이 비고 frontmatter (사이드카 유래 Title
  # 등) 만이 LLM 에 읽히는 경로가 열리기 때문. 멱등성은 "chunk MD 부재 → 일반 경로에서
  # 재추출" 로 유지된다.
  for p in "${CHUNK_PATHS[@]}"; do
    rm -f "${p}"
  done
  exit 3
fi

echo "${LOG_PREFIX} Extracted ${CHUNK_COUNT} chunk(s) from ${PDF_REAL} (pages=${EFFECTIVE_PAGES}/${PAGES})"
exit 0
