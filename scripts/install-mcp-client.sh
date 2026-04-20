#!/usr/bin/env bash
#
# install-mcp-client.sh — Claude Desktop / Claude Code 에 gieok-wiki MCP 를 등록 (Phase M)
#
# 기본 동작 (인자 없음 / --dry-run): 설정 스니펫을 stdout 에만 출력 (쓰지 않음)
# --apply  : Desktop 의 claude_desktop_config.json 에 jq 로 멱등 머지
# --uninstall: Desktop config 에서 "gieok-wiki" 를 삭제
#
# 환경 변수:
#   OBSIDIAN_VAULT          Vault 루트 (필수)
#   CLAUDE_DESKTOP_CONFIG   쓰기 대상 (기본 ~/Library/Application Support/Claude/claude_desktop_config.json)
#   GIEOK_NODE_BIN          Desktop 이 호출할 node 의 절대 경로 (기본 command -v node)
#   ASSUME_YES=1            --apply 확인 프롬프트를 스킵
#
# 종료 코드:
#   0  정상 종료
#   1  필수 환경 변수 부재 / 유효성 검증 실패
#   2  jq 부재 / JSON 손상 / 사용자 abort

set -euo pipefail

MODE="dry-run"
ASSUME_YES="${ASSUME_YES:-0}"
for arg in "$@"; do
  case "${arg}" in
    --apply) MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --uninstall) MODE="uninstall" ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "${arg}" >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# 전제
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MCP_DIR="${REPO_ROOT}/tools/claude-brain/mcp"
SERVER_ABS="${MCP_DIR}/server.mjs"
TEMPLATE_PATH="${REPO_ROOT}/tools/claude-brain/templates/mcp/claude_desktop_config.json.template"

if [[ ! -f "${SERVER_ABS}" ]]; then
  printf 'ERROR: server not found at %s\n' "${SERVER_ABS}" >&2
  exit 1
fi

if [[ ! -f "${TEMPLATE_PATH}" ]]; then
  printf 'ERROR: template not found at %s\n' "${TEMPLATE_PATH}" >&2
  exit 1
fi

OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-}"
if [[ -z "${OBSIDIAN_VAULT}" ]]; then
  printf 'ERROR: OBSIDIAN_VAULT is required\n' >&2
  exit 1
fi

validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ ${safe_re} ]]; then
    printf 'ERROR: OBSIDIAN_VAULT contains unsafe characters: %s\n' "${p}" >&2
    exit 1
  fi
}
validate_vault_path "${OBSIDIAN_VAULT}"

NODE_BIN="${GIEOK_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
if [[ -z "${NODE_BIN}" ]]; then
  printf 'ERROR: node not found in PATH (set GIEOK_NODE_BIN to absolute path)\n' >&2
  exit 1
fi

CONFIG_PATH="${CLAUDE_DESKTOP_CONFIG:-${HOME}/Library/Application Support/Claude/claude_desktop_config.json}"

# -----------------------------------------------------------------------------
# 템플릿 전개 (sed | 구분자, 치환 후 잔존 체크)
# -----------------------------------------------------------------------------

TMPWORK="$(mktemp -d)"
trap 'rm -rf "${TMPWORK}"' EXIT

SNIPPET="${TMPWORK}/snippet.json"
sed \
  -e "s|__NODE_BIN__|${NODE_BIN}|g" \
  -e "s|__SERVER_PATH__|${SERVER_ABS}|g" \
  -e "s|__OBSIDIAN_VAULT__|${OBSIDIAN_VAULT}|g" \
  "${TEMPLATE_PATH}" > "${SNIPPET}"

if grep -q '__[A-Z_]*__' "${SNIPPET}"; then
  printf 'ERROR: unresolved placeholders in snippet:\n' >&2
  grep -o '__[A-Z_]*__' "${SNIPPET}" >&2 || true
  exit 1
fi

# -----------------------------------------------------------------------------
# 안내 출력 (Claude Code 는 수동으로 `claude mcp add` 를 실행하도록 안내)
# -----------------------------------------------------------------------------

print_claude_code_instructions() {
  cat <<EOF

------------------------------------------------------------
Claude Code (CLI / VSCode 확장) 용 등록 명령:

  claude mcp add --scope user --transport stdio gieok \\
    "${NODE_BIN}" "${SERVER_ABS}"

확인:
  claude mcp list | grep gieok

비고: Claude Code 는 OBSIDIAN_VAULT 를 부모 프로세스에서 상속하므로
      셸 기동 시 ~/.zshrc 등에서 export 해 두었다면 추가 설정은 불필요합니다.
------------------------------------------------------------
EOF
}

# -----------------------------------------------------------------------------
# 모드 분기
# -----------------------------------------------------------------------------

case "${MODE}" in
  dry-run)
    printf '== Snippet (preview, NOT applied) ==\n'
    cat "${SNIPPET}"
    printf '\nTarget Desktop config: %s\n' "${CONFIG_PATH}"
    if [[ -f "${CONFIG_PATH}" ]]; then
      printf 'Status: already exists. Run with --apply to merge "gieok-wiki" key.\n'
    else
      printf 'Status: file does not exist. Run with --apply to create it.\n'
    fi
    print_claude_code_instructions
    exit 0
    ;;

  uninstall)
    if ! command -v jq >/dev/null 2>&1; then
      printf 'ERROR: jq is required for --uninstall\n' >&2
      exit 2
    fi
    if [[ ! -f "${CONFIG_PATH}" ]]; then
      printf '[skip] %s does not exist\n' "${CONFIG_PATH}"
      exit 0
    fi
    if ! jq -e . "${CONFIG_PATH}" >/dev/null 2>&1; then
      printf 'ERROR: %s is not valid JSON. Refusing to touch.\n' "${CONFIG_PATH}" >&2
      exit 2
    fi
    BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "${CONFIG_PATH}" "${BACKUP}"
    NEXT="${TMPWORK}/next.json"
    jq 'if has("mcpServers") then .mcpServers |= del(."gieok-wiki") else . end' \
      "${CONFIG_PATH}" > "${NEXT}"
    if ! jq -e . "${NEXT}" >/dev/null 2>&1; then
      printf 'ERROR: jq output not valid JSON. Backup at %s\n' "${BACKUP}" >&2
      exit 2
    fi
    mv "${NEXT}" "${CONFIG_PATH}"
    printf '[removed] gieok-wiki from %s\n' "${CONFIG_PATH}"
    printf 'backup:   %s\n' "${BACKUP}"
    printf 'NOTE: restart Claude Desktop for the change to take effect.\n'
    exit 0
    ;;

  apply)
    if ! command -v jq >/dev/null 2>&1; then
      printf 'ERROR: jq is required for --apply\n' >&2
      exit 2
    fi
    mkdir -p "$(dirname "${CONFIG_PATH}")"
    if [[ ! -f "${CONFIG_PATH}" ]]; then
      printf '{}\n' > "${CONFIG_PATH}"
      printf '[create] %s (was empty)\n' "${CONFIG_PATH}"
    fi
    if ! jq -e . "${CONFIG_PATH}" >/dev/null 2>&1; then
      printf 'ERROR: %s is not valid JSON. Refusing to touch.\n' "${CONFIG_PATH}" >&2
      exit 2
    fi

    BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "${CONFIG_PATH}" "${BACKUP}"

    MERGED="${TMPWORK}/merged.json"
    # 기존 mcpServers 를 유지한 채 gieok-wiki 키를 덮어쓰기 (멱등)
    jq --slurpfile snip "${SNIPPET}" '
      .mcpServers = ((.mcpServers // {}) + ($snip[0].mcpServers))
    ' "${CONFIG_PATH}" > "${MERGED}"

    if ! jq -e . "${MERGED}" >/dev/null 2>&1; then
      printf 'ERROR: merge output not valid JSON. Backup kept at %s\n' "${BACKUP}" >&2
      exit 2
    fi

    printf '== diff (old → new) ==\n'
    diff -u "${CONFIG_PATH}" "${MERGED}" || true
    printf '======================\n'
    printf 'target: %s\n' "${CONFIG_PATH}"
    printf 'backup: %s\n' "${BACKUP}"

    if [[ "${ASSUME_YES}" != "1" ]]; then
      printf 'Apply this change? [y/N] '
      read -r reply
      case "${reply}" in
        y|Y|yes|YES) ;;
        *)
          printf 'aborted. backup left at %s\n' "${BACKUP}"
          exit 2
          ;;
      esac
    fi

    mv "${MERGED}" "${CONFIG_PATH}"
    printf '[applied] %s\n' "${CONFIG_PATH}"
    printf 'rollback: mv "%s" "%s"\n' "${BACKUP}" "${CONFIG_PATH}"
    print_claude_code_instructions
    printf '\nNOTE: restart Claude Desktop for the change to take effect.\n'
    exit 0
    ;;
esac
