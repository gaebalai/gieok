#!/usr/bin/env bash
#
# setup-vault.sh — claude-brain Vault 초기화 스크립트
#
# $OBSIDIAN_VAULT 가 가리키는 Obsidian Vault 하위에 claude-brain 이 요구하는
# 디렉터리 구조, 초기 파일, .gitignore 를 "추가만" 한다.
# 기존 파일은 절대로 덮어쓰지 않는다 (멱등). git init 은 하지 않는다.
#
# 환경 변수:
#   OBSIDIAN_VAULT        (required) Vault 루트의 절대 경로
#   GIEOK_DRY_RUN  (optional) 1 이면 dry-run (실제로는 쓰지 않음)
#
# 종료 코드:
#   0  정상 종료
#   1  OBSIDIAN_VAULT 미설정
#   2  경로가 존재하지 않음 / 디렉터리가 아님
#   3  쓰기 권한 없음
#   4  내부 에러 (mkdir/cp 실패)

set -euo pipefail

# NEW-007: 안전한 퍼미션으로 Vault 를 생성한다 (umask 0002 환경에서도 0700/0600 보장)
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"

CREATED=0
SKIPPED=0
DRY_RUN="${GIEOK_DRY_RUN:-0}"

log_created() {
  CREATED=$((CREATED + 1))
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] [created] $1"
  else
    echo "[created] $1"
  fi
}

log_skipped() {
  SKIPPED=$((SKIPPED + 1))
  echo "[skipped] $1 (exists)"
}

log_warn() {
  echo "warning: $1" >&2
}

die() {
  local code="$1"
  shift
  echo "error: $*" >&2
  exit "${code}"
}

# OSS-007: OBSIDIAN_VAULT 유효성 검증 (셸 메타 문자 거부)
validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ $safe_re ]]; then
    echo "error: OBSIDIAN_VAULT contains unsafe characters: ${p}" >&2
    echo "       Only alphanumerics, /, ., _, space, and - are allowed." >&2
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# 입력 검증
# -----------------------------------------------------------------------------

if [[ -z "${OBSIDIAN_VAULT:-}" ]]; then
  cat >&2 <<'EOF'
error: OBSIDIAN_VAULT is not set.

Please set the environment variable to your Obsidian Vault path, e.g.:

  export OBSIDIAN_VAULT="$HOME/claude-brain/main-claude-brain"

Then re-run this script.
EOF
  exit 1
fi

validate_vault_path "${OBSIDIAN_VAULT}"

if [[ ! -e "${OBSIDIAN_VAULT}" ]]; then
  die 2 "OBSIDIAN_VAULT path does not exist: ${OBSIDIAN_VAULT}"
fi

if [[ ! -d "${OBSIDIAN_VAULT}" ]]; then
  die 2 "OBSIDIAN_VAULT is not a directory: ${OBSIDIAN_VAULT}"
fi

if [[ ! -w "${OBSIDIAN_VAULT}" ]]; then
  die 3 "OBSIDIAN_VAULT is not writable: ${OBSIDIAN_VAULT}"
fi

if [[ ! -d "${TEMPLATES_DIR}" ]]; then
  die 4 "templates directory not found: ${TEMPLATES_DIR}"
fi

# -----------------------------------------------------------------------------
# 디렉터리 생성
# -----------------------------------------------------------------------------

ensure_dir() {
  local dir="$1"
  if [[ -d "${dir}" ]]; then
    log_skipped "${dir}/"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_created "${dir}/"
    return 0
  fi
  mkdir -p "${dir}" || die 4 "mkdir failed: ${dir}"
  log_created "${dir}/"
}

DIRS=(
  "raw-sources/articles"
  "raw-sources/books"
  "raw-sources/papers"
  "raw-sources/transcripts"
  "raw-sources/ideas"
  "raw-sources/assets"
  "session-logs"
  "wiki/concepts"
  "wiki/projects"
  "wiki/decisions"
  "wiki/patterns"
  "wiki/bugs"
  "wiki/people"
  "wiki/summaries"
  "wiki/analyses"
  "wiki/meta"
  "templates"
)

for rel in "${DIRS[@]}"; do
  ensure_dir "${OBSIDIAN_VAULT}/${rel}"
done

# -----------------------------------------------------------------------------
# 초기 파일 배치
# -----------------------------------------------------------------------------

copy_if_missing() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "${src}" ]]; then
    die 4 "template source not found: ${src}"
  fi
  if [[ -e "${dst}" ]]; then
    log_skipped "${dst}"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_created "${dst}"
    return 0
  fi
  cp "${src}" "${dst}" || die 4 "cp failed: ${src} -> ${dst}"
  log_created "${dst}"
}

# CLAUDE.md 가 이미 있으면 CLAUDE.brain.md 로 대피 배치한다 (A.5)
install_vault_claude_md() {
  local src="${TEMPLATES_DIR}/vault/CLAUDE.md"
  local dst="${OBSIDIAN_VAULT}/CLAUDE.md"

  if [[ ! -f "${src}" ]]; then
    die 4 "template source not found: ${src}"
  fi

  if [[ -e "${dst}" ]]; then
    local alt="${OBSIDIAN_VAULT}/CLAUDE.brain.md"
    log_warn "Vault CLAUDE.md already exists. Writing schema to CLAUDE.brain.md instead."
    if [[ -e "${alt}" ]]; then
      log_skipped "${alt}"
      return 0
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_created "${alt}"
      return 0
    fi
    cp "${src}" "${alt}" || die 4 "cp failed: ${src} -> ${alt}"
    log_created "${alt}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_created "${dst}"
    return 0
  fi
  cp "${src}" "${dst}" || die 4 "cp failed: ${src} -> ${dst}"
  log_created "${dst}"
}

install_vault_claude_md

copy_if_missing \
  "${TEMPLATES_DIR}/vault/.gitignore" \
  "${OBSIDIAN_VAULT}/.gitignore"

copy_if_missing \
  "${TEMPLATES_DIR}/wiki/index.md" \
  "${OBSIDIAN_VAULT}/wiki/index.md"

copy_if_missing \
  "${TEMPLATES_DIR}/wiki/log.md" \
  "${OBSIDIAN_VAULT}/wiki/log.md"

# v0.6 Phase C-4: Obsidian Bases dashboard (wiki/meta/ 하위, 사용자가 Obsidian 에서 여는 대시보드)
copy_if_missing \
  "${TEMPLATES_DIR}/wiki/meta/dashboard.base" \
  "${OBSIDIAN_VAULT}/wiki/meta/dashboard.base"

copy_if_missing \
  "${TEMPLATES_DIR}/notes/concept.md" \
  "${OBSIDIAN_VAULT}/templates/concept.md"

copy_if_missing \
  "${TEMPLATES_DIR}/notes/project.md" \
  "${OBSIDIAN_VAULT}/templates/project.md"

copy_if_missing \
  "${TEMPLATES_DIR}/notes/decision.md" \
  "${OBSIDIAN_VAULT}/templates/decision.md"

copy_if_missing \
  "${TEMPLATES_DIR}/notes/source-summary.md" \
  "${OBSIDIAN_VAULT}/templates/source-summary.md"

# -----------------------------------------------------------------------------
# 요약
# -----------------------------------------------------------------------------

echo "Done. ${CREATED} created, ${SKIPPED} skipped."
