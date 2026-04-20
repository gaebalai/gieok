#!/usr/bin/env bash
#
# install-qmd-daemon.sh — claude-brain Phase J: qmd MCP 데몬의 launchd 등록
#
# qmd MCP 서버 (HTTP 모드) 를 macOS launchd 로 상주화한다.
# Mac 재기동 후에도 Claude Code 에서 qmd MCP 도구를 사용할 수 있는 상태를 유지한다.
#
# 배치 위치: ~/Library/LaunchAgents/com.gieok.qmd-mcp.plist
#
# 환경 변수:
#   QMD_MCP_PORT  리슨 포트 (기본 8181)
#
# 종료 코드:
#   0  정상 종료
#   1  qmd 명령이 PATH 에 없음 / launchctl 이 존재하지 않음 (비 macOS)
#
# 언인스톨:
#   launchctl unload ~/Library/LaunchAgents/com.gieok.qmd-mcp.plist
#   rm ~/Library/LaunchAgents/com.gieok.qmd-mcp.plist

set -euo pipefail

LABEL="com.gieok.qmd-mcp"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
PORT="${QMD_MCP_PORT:-8181}"

# NEW-003: 포트 번호 유효성 검증 (XML 인젝션 방지)
if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || [[ "${PORT}" -lt 1024 ]] || [[ "${PORT}" -gt 65535 ]]; then
  echo "ERROR: QMD_MCP_PORT must be a number between 1024 and 65535 (got: ${PORT})" >&2
  exit 1
fi

# cron 이나 비대화형 셸에서도 qmd 를 찾을 수 있도록 PATH 를 보완한다.
# (mise / volta 가 ~/.zshrc 경유로만 activate 되는 구성에도 대응)
#
# 중요: mise shims 를 Volta 보다 **먼저** 놓는다. qmd 는 mise 의 Node 에 대해
# native module (better-sqlite3) 을 빌드하므로 Volta 위의 다른 버전의
# Node 가 PATH 선두에 있으면 ABI mismatch 로 크래시한다.
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.volta/bin:${HOME}/.local/bin:${HOME}/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if ! command -v qmd >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: qmd command not found in PATH.

Install qmd first (any of):

  npm install -g @tobilu/qmd       # Volta / system Node
  mise use -g npm:@tobilu/qmd      # mise

Reference: https://github.com/tobi/qmd
EOF
  exit 1
fi

if ! command -v launchctl >/dev/null 2>&1; then
  echo "ERROR: launchctl not found. This script targets macOS only." >&2
  exit 1
fi

# 중요: mise / volta 의 shim (~/.local/share/mise/shims/qmd 등) 은 단일 바이너리로의
# hardlink 이며 argv[0] 의 basename 을 보고 dispatch 한다. `readlink -f` 로 실체 경로로
# 해결하면 basename 이 "mise" / "volta" 가 되어 qmd 를 기동할 수 없게 되므로
# command -v 가 반환하는 **shim 경로 그대로** plist 에 박는다. launchd 는 부모 셸 없이
# 절대 경로로 exec 하지만, shim 자체가 dispatch 정보를 가지고 있으므로 문제없다.
QMD_BIN="$(command -v qmd)"

# R4-002: QMD_BIN 경로 유효성 검증 (XML 인젝션 방지)
safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
if [[ ! "${QMD_BIN}" =~ $safe_re ]]; then
  echo "ERROR: qmd path contains unsafe characters: ${QMD_BIN}" >&2
  exit 1
fi

echo "============================================================"
echo "claude-brain: qmd MCP 데몬의 launchd 등록"
echo "============================================================"
echo "  Label      = ${LABEL}"
echo "  Plist      = ${PLIST_PATH}"
echo "  qmd binary = ${QMD_BIN}"
echo "  Port       = ${PORT}"
echo ""

mkdir -p "${PLIST_DIR}"
mkdir -p "${HOME}/.local/log"

# -----------------------------------------------------------------------------
# 기존 데몬이 돌고 있으면 일단 unload (멱등성 확보)
# -----------------------------------------------------------------------------

if [[ -f "${PLIST_PATH}" ]]; then
  echo "[unload] existing plist found, unloading first..."
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# plist 생성
# -----------------------------------------------------------------------------

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${QMD_BIN}</string>
        <string>mcp</string>
        <string>--http</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>${PORT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${HOME}/.local/share/mise/shims:${HOME}/.volta/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/.local/log/qmd-mcp.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.local/log/qmd-mcp.err</string>
</dict>
</plist>
EOF

echo "[written] ${PLIST_PATH}"

# -----------------------------------------------------------------------------
# launchctl load
# -----------------------------------------------------------------------------

if launchctl load "${PLIST_PATH}" 2>/dev/null; then
  echo "[loaded] launchctl load succeeded"
else
  echo "[warn] launchctl load failed; you can re-run manually:"
  echo "       launchctl load ${PLIST_PATH}"
fi

# -----------------------------------------------------------------------------
# MCP 설정 안내
# -----------------------------------------------------------------------------

cat <<EOF

============================================================
완료. 다음으로 Claude Code 에 qmd MCP 서버를 등록해 주세요
============================================================

아래 명령을 실행 (사용자 스코프에 등록):

  claude mcp add --scope user --transport http qmd http://localhost:${PORT}/mcp

확인:

  claude mcp list | grep qmd
  # => qmd: http://localhost:${PORT}/mcp (HTTP) - ✓ Connected

비고:
- Claude Code CLI 의 정규 설정 파일은 ~/.claude.json 입니다
  (~/.claude/settings.json 이나 VSCode 의 "claude.mcpServers" 는
   현재 Claude Code 에서 읽지 않습니다. 직접 편집하지 마세요)
- VSCode 확장판 Claude Code 도 같은 ~/.claude.json 을 읽으므로
  확장 쪽에서 별도로 등록할 필요는 없습니다. 재기동만 필요합니다

동작 확인:
  # 서버 소통
  curl -s http://localhost:${PORT}/mcp >/dev/null && echo OK || echo NG

  # 로그
  tail -f ~/.local/log/qmd-mcp.log ~/.local/log/qmd-mcp.err

언인스톨:
  launchctl unload ${PLIST_PATH}
  rm ${PLIST_PATH}
EOF
