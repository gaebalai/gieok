#!/usr/bin/env bash
#
# install-mcp-client.test.sh — scripts/install-mcp-client.sh 스모크 테스트 (Phase M)
#
# 검증 항목:
#   MCP29  --dry-run 으로 쓰기 없음, 출력에 치환 후 JSON 포함
#   MCP30  --apply 로 claude_desktop_config.json 에 gieok-wiki 키 추가, 기존 키 보존
#   MCP31  --apply 2회 실행 시 중복 없음 (멱등)
#   MCP32  --uninstall 로 gieok-wiki 만 삭제, 다른 서버 보존
#   MCP33  플레이스홀더 치환 후 __ 잔존 없음
#   MCP34  OBSIDIAN_VAULT 미설정 / unsafe path 에서 exit 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/tools/claude-brain/scripts/install-mcp-client.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

FAKE_VAULT="${TMPROOT}/vault"
mkdir -p "${FAKE_VAULT}/wiki" "${FAKE_VAULT}/session-logs"
CONFIG_PATH="${TMPROOT}/claude_desktop_config.json"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  NG  $1" >&2; }

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3 (expected=$1, actual=$2)"
  fi
}

assert_contains() {
  if printf '%s' "$1" | grep -q -F -- "$2"; then
    pass "$3"
  else
    fail "$3 (substring not found: $2)"
  fi
}

run_install() {
  local out rc
  set +e
  out=$(
    OBSIDIAN_VAULT="${FAKE_VAULT}" \
    CLAUDE_DESKTOP_CONFIG="${CONFIG_PATH}" \
    ASSUME_YES=1 \
    bash "${INSTALL_SCRIPT}" "$@" 2>&1
  )
  rc=$?
  set -e
  printf '%s\n' "${out}"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# MCP29: --dry-run, no write
# -----------------------------------------------------------------------------
echo "== MCP29: --dry-run =="
out=$(run_install --dry-run) || rc=$? && rc=0
assert_eq "0" "${rc}" "MCP29 dry-run exits 0"
assert_contains "${out}" '"gieok-wiki"' "MCP29 emits snippet"
assert_contains "${out}" "Snippet (preview" "MCP29 marks output as preview"
if [[ -f "${CONFIG_PATH}" ]]; then
  fail "MCP29 dry-run must not write config"
else
  pass "MCP29 config not written"
fi

# -----------------------------------------------------------------------------
# MCP33: placeholder leftover check
# -----------------------------------------------------------------------------
echo "== MCP33: placeholder leftover =="
if printf '%s' "${out}" | grep -q '__[A-Z_]*__'; then
  fail "MCP33 dry-run output still contains placeholders"
else
  pass "MCP33 dry-run output has no placeholders"
fi

# -----------------------------------------------------------------------------
# MCP30: --apply creates new config preserving none-existing other servers
# -----------------------------------------------------------------------------
echo "== MCP30: --apply on fresh config =="
# Pre-seed the file with another mcpServer
mkdir -p "$(dirname "${CONFIG_PATH}")"
cat > "${CONFIG_PATH}" <<'JSON'
{
  "mcpServers": {
    "qmd": {
      "url": "http://localhost:8181/mcp"
    }
  }
}
JSON

out=$(run_install --apply) || rc=$? && rc=0
assert_eq "0" "${rc}" "MCP30 apply exits 0"
if jq -e '.mcpServers."gieok-wiki".command' "${CONFIG_PATH}" >/dev/null; then
  pass "MCP30 gieok-wiki key added"
else
  fail "MCP30 gieok-wiki key missing"
fi
if jq -e '.mcpServers.qmd.url' "${CONFIG_PATH}" >/dev/null; then
  pass "MCP30 existing qmd key preserved"
else
  fail "MCP30 existing qmd key was removed"
fi

# Backup created
if ls "${CONFIG_PATH}".bak.* >/dev/null 2>&1; then
  pass "MCP30 backup created"
else
  fail "MCP30 backup missing"
fi

# -----------------------------------------------------------------------------
# MCP31: --apply twice is idempotent
# -----------------------------------------------------------------------------
echo "== MCP31: --apply idempotent =="
SHA_BEFORE="$(jq -S 'del(.["__ignored"])' "${CONFIG_PATH}" | shasum)"
out=$(run_install --apply) || true
SHA_AFTER="$(jq -S 'del(.["__ignored"])' "${CONFIG_PATH}" | shasum)"
assert_eq "${SHA_BEFORE}" "${SHA_AFTER}" "MCP31 second apply leaves config unchanged"

# -----------------------------------------------------------------------------
# MCP32: --uninstall removes only gieok-wiki
# -----------------------------------------------------------------------------
echo "== MCP32: --uninstall =="
out=$(run_install --uninstall) || rc=$? && rc=0
assert_eq "0" "${rc}" "MCP32 uninstall exits 0"
if jq -e '.mcpServers."gieok-wiki"' "${CONFIG_PATH}" >/dev/null 2>&1; then
  fail "MCP32 gieok-wiki still present"
else
  pass "MCP32 gieok-wiki removed"
fi
if jq -e '.mcpServers.qmd.url' "${CONFIG_PATH}" >/dev/null; then
  pass "MCP32 qmd preserved"
else
  fail "MCP32 qmd removed"
fi

# -----------------------------------------------------------------------------
# MCP34: missing OBSIDIAN_VAULT exits 1
# -----------------------------------------------------------------------------
echo "== MCP34: OBSIDIAN_VAULT validation =="
set +e
out=$(CLAUDE_DESKTOP_CONFIG="${CONFIG_PATH}" OBSIDIAN_VAULT='' bash "${INSTALL_SCRIPT}" --dry-run 2>&1)
rc=$?
set -e
assert_eq "1" "${rc}" "MCP34 unset vault exits 1"
assert_contains "${out}" "OBSIDIAN_VAULT" "MCP34 mentions OBSIDIAN_VAULT"

set +e
out=$(CLAUDE_DESKTOP_CONFIG="${CONFIG_PATH}" OBSIDIAN_VAULT='/tmp/$(rm -rf /)' bash "${INSTALL_SCRIPT}" --dry-run 2>&1)
rc=$?
set -e
assert_eq "1" "${rc}" "MCP34 unsafe vault chars exit 1"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "==========================="
echo "  passed: ${PASS}"
echo "  failed: ${FAIL}"
echo "==========================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
