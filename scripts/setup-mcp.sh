#!/usr/bin/env bash
#
# setup-mcp.sh — GIEOK MCP 서버의 의존성 셋업 (Phase M)
#
# tools/claude-brain/mcp/ 하위에 @modelcontextprotocol/sdk 를 npm install 한다.
# 부모 레포는 package.json 을 두지 않는 방침이므로 mcp/ 서브디렉터리 단독으로 완결된다.
#
# 종료 코드:
#   0  정상 종료 (이미 설치되어 있어도 여기로 귀착)
#   1  node 부재 / 버전 부족 / npm 부재
#
# 사용법:
#   bash tools/claude-brain/scripts/setup-mcp.sh             # 실제 install
#   bash tools/claude-brain/scripts/setup-mcp.sh --dry-run   # 확인만
#
# 언인스톨:
#   rm -rf tools/claude-brain/mcp/node_modules

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$(cd "${SCRIPT_DIR}/../mcp" && pwd)"

echo "setup-mcp: mcp dir = ${MCP_DIR}"

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
  {
    printf '%s\n' 'ERROR: node not found in PATH.'
    printf '%s\n' ''
    printf '%s\n' 'Install Node.js 18+ first (any of):'
    printf '%s\n' ''
    printf '%s\n' '  brew install node            # Homebrew'
    printf '%s\n' '  mise use -g node@22          # mise'
    printf '%s\n' '  volta install node           # Volta'
    printf '%s\n' ''
    printf '%s\n' 'Reference: https://nodejs.org/'
  } >&2
  exit 1
fi

NODE_VERSION="$(node --version 2>/dev/null | sed 's/^v//')"
NODE_MAJOR="${NODE_VERSION%%.*}"
if [[ ! "${NODE_MAJOR}" =~ ^[0-9]+$ ]] || [[ "${NODE_MAJOR}" -lt 18 ]]; then
  echo "ERROR: Node 18+ required (found: ${NODE_VERSION})" >&2
  exit 1
fi
echo "setup-mcp: node = $(command -v node) (v${NODE_VERSION})"

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm not found in PATH" >&2
  exit 1
fi

if [[ ! -f "${MCP_DIR}/package.json" ]]; then
  echo "ERROR: ${MCP_DIR}/package.json not found" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# install
# -----------------------------------------------------------------------------

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] cd ${MCP_DIR} && npm install --omit=dev --no-audit --no-fund"
  echo "[dry-run] (no changes made)"
  exit 0
fi

if [[ -d "${MCP_DIR}/node_modules/@modelcontextprotocol/sdk" ]]; then
  SDK_VERSION="$(node -p "require('${MCP_DIR}/node_modules/@modelcontextprotocol/sdk/package.json').version" 2>/dev/null || echo unknown)"
  echo "setup-mcp: [skip] @modelcontextprotocol/sdk ${SDK_VERSION} already installed"
else
  echo "setup-mcp: [install] running npm install..."
  (cd "${MCP_DIR}" && npm install --omit=dev --no-audit --no-fund)
  SDK_VERSION="$(node -p "require('${MCP_DIR}/node_modules/@modelcontextprotocol/sdk/package.json').version" 2>/dev/null || echo unknown)"
  echo "setup-mcp: [done] @modelcontextprotocol/sdk ${SDK_VERSION}"
fi

cat <<EOF

============================================================
완료. 다음으로 Claude Desktop / Claude Code 에 gieok MCP 를 등록해 주세요
============================================================

  bash tools/claude-brain/scripts/install-mcp-client.sh --dry-run   # 확인
  bash tools/claude-brain/scripts/install-mcp-client.sh --apply     # 등록

EOF
