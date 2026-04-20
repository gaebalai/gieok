#!/usr/bin/env bash
#
# install-launchagents.sh — macOS 용 claude-brain 정기 실행 셋업 (Phase L)
#
# templates/launchd/*.plist.template 를 플레이스홀더 치환하여
# $HOME/Library/LaunchAgents/ (또는 CLAUDE_LAUNCHAGENTS_DIR) 에 배치하고
# launchctl bootstrap 으로 로드한다. 멱등적으로 동작한다.
#
# Usage:
#   bash install-launchagents.sh              # 멱등 plist 배치 + load
#   bash install-launchagents.sh --dry-run    # 예정만 표시, 쓰기 없음
#   bash install-launchagents.sh --force      # 기존 plist 를 덮어쓰기
#   bash install-launchagents.sh --uninstall  # bootout + plist 삭제
#   bash install-launchagents.sh -h           # 도움말
#
# 환경 변수:
#   OBSIDIAN_VAULT            Vault 루트 (필수)
#   CLAUDE_LAUNCHAGENTS_DIR   plist 배치 대상 (기본: $HOME/Library/LaunchAgents)
#                             테스트 시 mktemp 대상으로 교체
#   GIEOK_SKIP_LOAD    1 이면 launchctl bootstrap/bootout 을 호출하지 않는다 (테스트용)
#
# 종료 코드:
#   0  정상 종료
#   1  필수 환경 변수 부재 / 파일 부재
#   2  기존 plist 가 동일하지 않으며 --force 미지정
#   3  launchctl bootstrap 실패
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${TOOL_ROOT}/templates/launchd"
AUTO_INGEST_ABS="${SCRIPT_DIR}/auto-ingest.sh"
AUTO_LINT_ABS="${SCRIPT_DIR}/auto-lint.sh"

DEST_DIR="${CLAUDE_LAUNCHAGENTS_DIR:-${HOME}/Library/LaunchAgents}"

FORCE=0
DRY_RUN=0
UNINSTALL=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# VULN-005: 경로 유효성 검증 (셸 메타 문자・XML 특수 문자 거부)
validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ $safe_re ]]; then
    echo "ERROR: OBSIDIAN_VAULT contains unsafe characters: ${p}" >&2
    echo "       Only alphanumerics, /, ., _, space, and - are allowed." >&2
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if [[ "${UNINSTALL}" -eq 0 ]]; then
  # 설치 시에만 OBSIDIAN_VAULT 가 필수
  if [[ -z "${OBSIDIAN_VAULT:-}" ]]; then
    echo "ERROR: OBSIDIAN_VAULT is not set" >&2
    echo "       export OBSIDIAN_VAULT=/path/to/your/vault" >&2
    exit 1
  fi

  validate_vault_path "${OBSIDIAN_VAULT}"

  if [[ ! -f "${AUTO_INGEST_ABS}" ]]; then
    echo "ERROR: auto-ingest.sh not found at ${AUTO_INGEST_ABS}" >&2
    exit 1
  fi

  if [[ ! -f "${AUTO_LINT_ABS}" ]]; then
    echo "ERROR: auto-lint.sh not found at ${AUTO_LINT_ABS}" >&2
    exit 1
  fi

  if [[ ! -d "${TEMPLATE_DIR}" ]]; then
    echo "ERROR: template directory not found: ${TEMPLATE_DIR}" >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# LaunchAgent 대상 목록
# -----------------------------------------------------------------------------
# template_name:label 의 2 요소
AGENTS=(
  "com.gieok.ingest.plist.template:com.gieok.ingest"
  "com.gieok.lint.plist.template:com.gieok.lint"
)

# -----------------------------------------------------------------------------
# 유틸리티
# -----------------------------------------------------------------------------
generate_plist() {
  local template="$1"
  local dest="$2"
  # sed 의 구분자는 경로에 포함되지 않는 `|` 를 사용
  sed \
    -e "s|__AUTO_INGEST_SH__|${AUTO_INGEST_ABS}|g" \
    -e "s|__AUTO_LINT_SH__|${AUTO_LINT_ABS}|g" \
    -e "s|__OBSIDIAN_VAULT__|${OBSIDIAN_VAULT}|g" \
    -e "s|__HOME__|${HOME}|g" \
    "${template}" > "${dest}"
}

files_equal() {
  # 두 파일의 내용이 동일하면 0, 그 외에는 1
  if [[ ! -f "$1" ]] || [[ ! -f "$2" ]]; then
    return 1
  fi
  cmp -s "$1" "$2"
}

launchctl_bootstrap() {
  local label="$1"
  local plist="$2"
  if [[ "${GIEOK_SKIP_LOAD:-0}" == "1" ]]; then
    echo "  [skip-load]  ${label} (GIEOK_SKIP_LOAD=1)"
    return 0
  fi
  local uid
  uid="$(id -u)"
  # 이미 로드되어 있으면 bootout 한다 (멱등성)
  if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
    launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  fi
  if ! launchctl bootstrap "gui/${uid}" "${plist}" 2>&1; then
    echo "ERROR: launchctl bootstrap failed for ${label}" >&2
    return 3
  fi
  echo "  [loaded]  ${label}"
}

launchctl_bootout() {
  local label="$1"
  if [[ "${GIEOK_SKIP_LOAD:-0}" == "1" ]]; then
    return 0
  fi
  local uid
  uid="$(id -u)"
  if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
    launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
    echo "  [unloaded]  ${label}"
  fi
}

# -----------------------------------------------------------------------------
# --uninstall 경로
# -----------------------------------------------------------------------------
if [[ "${UNINSTALL}" -eq 1 ]]; then
  echo "install-launchagents: uninstalling from ${DEST_DIR}"
  for entry in "${AGENTS[@]}"; do
    label="${entry##*:}"
    dest="${DEST_DIR}/${label}.plist"
    launchctl_bootout "${label}"
    if [[ -f "${dest}" ]]; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "  [dry-run] would rm ${dest}"
      else
        rm "${dest}"
        echo "  [removed]  ${label}.plist"
      fi
    else
      echo "  [absent]   ${label}.plist"
    fi
  done
  echo "install-launchagents: uninstall complete."
  exit 0
fi

# -----------------------------------------------------------------------------
# 설치 경로
# -----------------------------------------------------------------------------
echo "install-launchagents: dest     = ${DEST_DIR}"
echo "install-launchagents: vault    = ${OBSIDIAN_VAULT}"
echo "install-launchagents: ingest   = ${AUTO_INGEST_ABS}"
echo "install-launchagents: lint     = ${AUTO_LINT_ABS}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "install-launchagents: DRY RUN (no files will be written)"
fi
echo

if [[ "${DRY_RUN}" -eq 0 ]]; then
  mkdir -p "${DEST_DIR}"
fi

TMPWORK="$(mktemp -d)"
trap 'rm -rf "${TMPWORK}"' EXIT

CREATED=0
SKIPPED=0
REPLACED=0
WARNED=0

for entry in "${AGENTS[@]}"; do
  template_name="${entry%%:*}"
  label="${entry##*:}"

  template_path="${TEMPLATE_DIR}/${template_name}"
  dest="${DEST_DIR}/${label}.plist"

  if [[ ! -f "${template_path}" ]]; then
    echo "ERROR: template not found: ${template_path}" >&2
    exit 1
  fi

  # 임시 파일로 전개하여 기존 파일과 비교
  staged="${TMPWORK}/${label}.plist"
  generate_plist "${template_path}" "${staged}"

  # 플레이스홀더가 남아 있지 않은지 검증
  if grep -q '__[A-Z_]*__' "${staged}" 2>/dev/null; then
    echo "ERROR: unresolved placeholders in ${staged}:" >&2
    grep -o '__[A-Z_]*__' "${staged}" >&2 || true
    exit 1
  fi

  if [[ -e "${dest}" ]]; then
    if files_equal "${staged}" "${dest}"; then
      echo "  [skip]    ${label}.plist (already up to date)"
      SKIPPED=$((SKIPPED + 1))
      # 기존 plist 가 올바르게 로드되어 있는지 만일을 위해 확인 (load state 는 별도)
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        launchctl_bootstrap "${label}" "${dest}" || true
      fi
      continue
    fi

    if [[ "${FORCE}" -eq 1 ]]; then
      echo "  [force]   ${label}.plist (overwriting)"
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        cp "${staged}" "${dest}"
        launchctl_bootstrap "${label}" "${dest}" || exit 3
      fi
      REPLACED=$((REPLACED + 1))
      continue
    fi

    echo "  [WARN]    ${label}.plist exists and differs; use --force to overwrite" >&2
    WARNED=$((WARNED + 1))
    continue
  fi

  echo "  [create]  ${label}.plist"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    cp "${staged}" "${dest}"
    launchctl_bootstrap "${label}" "${dest}" || exit 3
  fi
  CREATED=$((CREATED + 1))
done

echo
echo "install-launchagents: created=${CREATED} replaced=${REPLACED} skipped=${SKIPPED} warned=${WARNED}"

if [[ "${WARNED}" -gt 0 ]]; then
  exit 2
fi

if [[ "${DRY_RUN}" -eq 0 ]] && [[ "${GIEOK_SKIP_LOAD:-0}" != "1" ]]; then
  cat <<EOF

============================================================
다음으로 확인할 수 있는 것
============================================================

  # 등록 상태
  launchctl list | grep gieok

  # 상세
  launchctl print gui/\$(id -u)/com.gieok.ingest | head -30

  # 즉시 실행 (디버그용)
  launchctl kickstart -k gui/\$(id -u)/com.gieok.ingest
  tail -f ~/gieok-ingest.log

다음 자동 실행 시각 (ingest): 07:00 / 13:00 / 19:00
다음 자동 실행 시각 (lint):   매월 1일 08:00

============================================================
EOF
fi
