#!/usr/bin/env bash
#
# extract-url.sh — 기능 2.2: URL fetch + Markdown 변환용 shell thin wrapper
#
# 사용법:
#   extract-url.sh --url <url> --vault <vault> [options]
#   extract-url.sh --urls-file <path> --vault <vault> --subdir <subdir>
#
# 옵션:
#   --url <url>             단일 URL 을 처리
#   --urls-file <path>      urls.txt 형식 파일을 순차 처리
#   --vault <path>          Vault 루트 (필수)
#   --subdir <name>         raw-sources 서브디렉터리 (기본: articles)
#   --refresh-days <n|never>
#   --title <s>             타이틀 덮어쓰기 (단일 URL 만)
#   --source-type <s>
#   --tags <a,b,c>
#   --robots-override <url>
#   --help
#
# exit code 는 mcp/lib/url-extract-cli.mjs 의 전파:
#   0 = ok (urls-file 은 줄 단위 실패는 warning 으로 두고 최종 exit 는 0)
#   1 = node 가 PATH 에 없음, CLI 파일 누락
#   2 = 인자 에러 (--url / --urls-file / --vault 누락, 알 수 없는 플래그)

set -euo pipefail
LOG_PREFIX="[extract-url]"

# 2026-04-20 LOW-d4 fix: cron / launchd 를 통해 호출될 때 operator 가 debug 용으로
# 남긴 `GIEOK_URL_ALLOW_LOOPBACK` / `GIEOK_URL_IGNORE_ROBOTS` 가 영속적 bypass 가
# 되는 경로를 막는다. 셸 쪽에서 명시적으로 unset 하여 node CLI 에 전파하지 않는다.
# 테스트 목적으로 loopback fixture-server 를 허용하고 싶다면
# `GIEOK_ALLOW_LOOPBACK_IN_CRON=1` 을 지정할 것 (최소한의 allowlist flag).
if [[ "${GIEOK_ALLOW_LOOPBACK_IN_CRON:-0}" != "1" ]]; then
  unset GIEOK_URL_ALLOW_LOOPBACK
fi
if [[ "${GIEOK_ALLOW_IGNORE_ROBOTS_IN_CRON:-0}" != "1" ]]; then
  unset GIEOK_URL_IGNORE_ROBOTS
fi

usage() {
  cat <<EOF
Usage: extract-url.sh --url <url> --vault <vault> [options]
       extract-url.sh --urls-file <path> --vault <vault> --subdir <subdir>

Options:
  --url <url>             Single URL to process
  --urls-file <path>      Process urls.txt sequentially (lines: "URL [; key=value ...]")
  --vault <path>          Vault root (required)
  --subdir <name>         raw-sources subdir (default: articles)
  --refresh-days <n|never>
  --title <s>             Override title (single URL only)
  --source-type <s>
  --tags <a,b,c>
  --robots-override <url>
  --help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${SCRIPT_DIR}/../mcp/lib/url-extract-cli.mjs"

URL=""
URLS_FILE=""
VAULT=""
SUBDIR="articles"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --url)
      [[ $# -ge 2 ]] || { echo "${LOG_PREFIX} ERROR: --url requires value" >&2; exit 2; }
      URL="$2"; shift 2 ;;
    --urls-file)
      [[ $# -ge 2 ]] || { echo "${LOG_PREFIX} ERROR: --urls-file requires value" >&2; exit 2; }
      URLS_FILE="$2"; shift 2 ;;
    --vault)
      [[ $# -ge 2 ]] || { echo "${LOG_PREFIX} ERROR: --vault requires value" >&2; exit 2; }
      VAULT="$2"; shift 2 ;;
    --subdir)
      [[ $# -ge 2 ]] || { echo "${LOG_PREFIX} ERROR: --subdir requires value" >&2; exit 2; }
      SUBDIR="$2"; shift 2 ;;
    --refresh-days|--title|--source-type|--tags|--robots-override)
      [[ $# -ge 2 ]] || { echo "${LOG_PREFIX} ERROR: $1 requires value" >&2; exit 2; }
      EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
    *)
      echo "${LOG_PREFIX} ERROR: unknown flag: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "${URL}" && -z "${URLS_FILE}" ]]; then
  echo "${LOG_PREFIX} ERROR: --url required (or --urls-file)" >&2
  exit 2
fi
if [[ -z "${VAULT}" ]]; then
  echo "${LOG_PREFIX} ERROR: --vault required" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "${LOG_PREFIX} ERROR: node not found in PATH" >&2
  exit 1
fi
if [[ ! -f "${CLI}" ]]; then
  echo "${LOG_PREFIX} ERROR: CLI not found: ${CLI}" >&2
  exit 1
fi

run_one() {
  local u="$1"; shift
  local args=(--url "${u}" --vault "${VAULT}" --subdir "${SUBDIR}")
  if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    args+=("${EXTRA_ARGS[@]}")
  fi
  # Caller may append per-entry DSL flags via $@.
  if [[ $# -gt 0 ]]; then
    args+=("$@")
  fi
  # `|| rc=$?` so that set -e does not trip on non-zero node CLI exits; the caller
  # handles the return value explicitly.
  local rc=0
  node "${CLI}" "${args[@]}" || rc=$?
  return ${rc}
}

# Single URL path.
if [[ -n "${URL}" ]]; then
  run_one "${URL}"
  exit $?
fi

# urls.txt loop.
if [[ ! -f "${URLS_FILE}" ]]; then
  echo "${LOG_PREFIX} ERROR: urls-file not found: ${URLS_FILE}" >&2
  exit 2
fi

process_entry() {
  local raw_line="$1"
  # 주석 제거: 행 선두 # 또는 공백+# 이후.
  # 공백+# 는 tr 로 간단히 검출하기 어렵기 때문에 grep 으로 행 전체를 검사한다.
  local stripped
  stripped="$(printf '%s\n' "${raw_line}" | awk '
    {
      line = $0
      # 행 선두 # (공백 포함) → 빈 줄 취급
      sub(/^[[:space:]]+/, "", line)
      if (substr(line, 1, 1) == "#") { print ""; next }
      # 공백 + # 이후를 자름
      idx = index($0, " #")
      if (idx > 0) { print substr($0, 1, idx - 1); next }
      print $0
    }
  ')"
  # trim
  stripped="$(printf '%s' "${stripped}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "${stripped}" ]] && return 0

  # URL 부분 (첫 번째 ; 앞까지)
  local url_part
  if [[ "${stripped}" == *";"* ]]; then
    url_part="${stripped%%;*}"
  else
    url_part="${stripped}"
  fi
  url_part="$(printf '%s' "${url_part}" | sed -e 's/[[:space:]]*$//')"

  if [[ ! "${url_part}" =~ ^https?:// ]]; then
    echo "${LOG_PREFIX} WARN: skip non-URL: ${url_part}" >&2
    return 0
  fi

  # DSL: ; key=value 를 --flag value 로 변환. 알 수 없는 key 는 warning.
  local dsl_args=()
  if [[ "${stripped}" == *";"* ]]; then
    local rest="${stripped#*;}"
    local IFS_BAK="${IFS}"
    local IFS=';'
    # shellcheck disable=SC2206
    local parts=(${rest})
    IFS="${IFS_BAK}"
    local part key val flag
    for part in "${parts[@]}"; do
      part="$(printf '%s' "${part}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -z "${part}" ]] && continue
      if [[ "${part}" != *"="* ]]; then
        echo "${LOG_PREFIX} WARN: malformed DSL segment (no '='): ${part}" >&2
        continue
      fi
      key="${part%%=*}"
      val="${part#*=}"
      key="$(printf '%s' "${key}" | sed -e 's/[[:space:]]*$//')"
      val="$(printf '%s' "${val}" | sed -e 's/^[[:space:]]*//')"
      case "${key}" in
        tags|title|source_type|refresh_days)
          flag="--${key//_/-}"
          dsl_args+=("${flag}" "${val}") ;;
        *)
          echo "${LOG_PREFIX} WARN: unknown DSL key: ${key}" >&2 ;;
      esac
    done
  fi

  echo "${LOG_PREFIX} Processing: ${url_part}"
  local rc=0
  if [[ ${#dsl_args[@]} -gt 0 ]]; then
    run_one "${url_part}" "${dsl_args[@]}" || rc=$?
  else
    run_one "${url_part}" || rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    echo "${LOG_PREFIX} WARN: ${url_part} failed (rc=${rc})" >&2
  fi
  return 0
}

while IFS= read -r line || [[ -n "${line}" ]]; do
  process_entry "${line}" || true
done < "${URLS_FILE}"

exit 0
