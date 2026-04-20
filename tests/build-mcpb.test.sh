#!/usr/bin/env bash
#
# build-mcpb.test.sh — scripts/build-mcpb.sh 스모크 테스트 (Phase N)
#
# 실행: bash tools/claude-brain/tests/build-mcpb.test.sh
#
# 검증 항목:
#   MCPB1  --help 가 usage 를 표시
#   MCPB2  unknown 인자로 exit 1
#   MCPB3  --validate 가 schema 검증에 성공
#   MCPB4  --dry-run 으로 staging 이 구성되고, 필요한 파일들이 갖춰짐
#   MCPB5  --clean 으로 build/ 와 dist/ 가 삭제됨
#   MCPB6  manifest.json 이 "name": "gieok-wiki" 를 포함
#   MCPB7  manifest.json 이 user_config.vault_path (type=directory, required) 를 가짐
#   MCPB8  manifest.json 이 server.mcp_config.env.OBSIDIAN_VAULT 치환을 가짐
#
# 네트워크 액세스:
#   --validate 는 npx 경유로 `@anthropic-ai/mcpb` 를 기동하므로, 초회에는 캐시
#   다운로드가 발생한다. CI 에서 skip 하려면 GIEOK_SKIP_MCPB_NETWORK=1 을 설정한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_SCRIPT="${REPO_ROOT}/tools/claude-brain/scripts/build-mcpb.sh"
MANIFEST="${REPO_ROOT}/tools/claude-brain/mcp/manifest.json"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  ok  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  NG  $1" >&2
}

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

# -----------------------------------------------------------------------------
# MCPB1: --help prints usage
# -----------------------------------------------------------------------------
echo "== MCPB1: --help =="
set +e
out=$(bash "${BUILD_SCRIPT}" --help 2>&1)
rc=$?
set -e
assert_eq "0" "${rc}" "MCPB1 exit code is 0"
assert_contains "${out}" "build-mcpb.sh" "MCPB1 mentions script name"
assert_contains "${out}" "--dry-run" "MCPB1 documents --dry-run"

# -----------------------------------------------------------------------------
# MCPB2: unknown argument exits 1
# -----------------------------------------------------------------------------
echo "== MCPB2: unknown argument =="
set +e
out=$(bash "${BUILD_SCRIPT}" --not-a-real-flag 2>&1)
rc=$?
set -e
assert_eq "1" "${rc}" "MCPB2 exit code is 1"
assert_contains "${out}" "unknown argument" "MCPB2 reports unknown argument"

# -----------------------------------------------------------------------------
# MCPB3: --validate succeeds against the bundled mcpb CLI
# -----------------------------------------------------------------------------
if [[ "${GIEOK_SKIP_MCPB_NETWORK:-0}" == "1" ]]; then
  echo "== MCPB3: --validate (skipped: GIEOK_SKIP_MCPB_NETWORK=1) =="
else
  echo "== MCPB3: --validate =="
  set +e
  out=$(bash "${BUILD_SCRIPT}" --validate 2>&1)
  rc=$?
  set -e
  assert_eq "0" "${rc}" "MCPB3 exit code is 0"
  assert_contains "${out}" "Manifest schema validation passes" "MCPB3 manifest validates"
fi

# -----------------------------------------------------------------------------
# MCPB4: --dry-run builds staging and lists tree
# -----------------------------------------------------------------------------
echo "== MCPB4: --dry-run =="
set +e
out=$(bash "${BUILD_SCRIPT}" --dry-run 2>&1)
rc=$?
set -e
assert_eq "0" "${rc}" "MCPB4 exit code is 0"
assert_contains "${out}" "[stage] copying manifest" "MCPB4 stages manifest"
assert_contains "${out}" "[stage] copying server code" "MCPB4 stages server code"
assert_contains "${out}" "would run: npx" "MCPB4 prints would-be pack command"

STAGING="${REPO_ROOT}/tools/claude-brain/mcp/build/staging"
[[ -f "${STAGING}/manifest.json" ]] && pass "MCPB4 staging manifest exists" \
  || fail "MCPB4 staging manifest missing"
[[ -f "${STAGING}/server/server.mjs" ]] && pass "MCPB4 staging server.mjs exists" \
  || fail "MCPB4 staging server.mjs missing"
[[ -d "${STAGING}/server/lib" ]] && pass "MCPB4 staging lib/ exists" \
  || fail "MCPB4 staging lib/ missing"
[[ -d "${STAGING}/server/tools" ]] && pass "MCPB4 staging tools/ exists" \
  || fail "MCPB4 staging tools/ missing"
[[ -d "${STAGING}/server/node_modules/@modelcontextprotocol/sdk" ]] \
  && pass "MCPB4 staging bundles @modelcontextprotocol/sdk" \
  || fail "MCPB4 staging missing @modelcontextprotocol/sdk"

# -----------------------------------------------------------------------------
# MCPB4b (v0.3.3 regression test): staging 에 MCP-invoked shell scripts 가 포함됨
#
# v0.2.0-v0.3.2 의 .mcpb bundle 은 scripts/ 를 staging 에 포함하지 않았기 때문에,
# Claude Desktop 경유로 gieok_ingest_pdf 를 호출하면 `extract-pdf.sh: No such file or
# directory` (rc=127) 로 실패했다. v0.3.3 에서 scripts/ staging 복사를 추가.
# 본 테스트는 regression 방지 (로컬 build 가 아닌 .mcpb 경유로 tool 이 동작하는 전제를 고정).
# -----------------------------------------------------------------------------
[[ -f "${STAGING}/scripts/extract-pdf.sh" ]] \
  && pass "MCPB4b staging includes scripts/extract-pdf.sh (gieok_ingest_pdf 의존)" \
  || fail "MCPB4b staging missing scripts/extract-pdf.sh — gieok_ingest_pdf will fail at runtime"
[[ -x "${STAGING}/scripts/extract-pdf.sh" ]] \
  && pass "MCPB4b extract-pdf.sh is executable (0o755)" \
  || fail "MCPB4b extract-pdf.sh lacks execute permission"
[[ -f "${STAGING}/scripts/mask-text.mjs" ]] \
  && pass "MCPB4b staging includes scripts/mask-text.mjs (extract-pdf.sh 의존)" \
  || fail "MCPB4b staging missing scripts/mask-text.mjs"
[[ -f "${STAGING}/scripts/lib/masking.mjs" ]] \
  && pass "MCPB4b staging includes scripts/lib/masking.mjs (mask-text.mjs 의존)" \
  || fail "MCPB4b staging missing scripts/lib/masking.mjs"
[[ -f "${STAGING}/scripts/extract-url.sh" ]] \
  && pass "MCPB4b staging includes scripts/extract-url.sh (향후 MCP spawn 용)" \
  || fail "MCPB4b staging missing scripts/extract-url.sh"
# auto-ingest.sh / install-*.sh / setup-*.sh 는 MCP 에서 spawn 되지 않으므로 staging 에 포함되지 않음
[[ ! -f "${STAGING}/scripts/auto-ingest.sh" ]] \
  && pass "MCPB4b staging excludes cron-only scripts/auto-ingest.sh (최소 배포)" \
  || fail "MCPB4b staging includes scripts/auto-ingest.sh (불필요하게 동봉됨)"

# ingest-pdf.mjs 의 path 해결 정합성 확인:
# `join(__dirname, '..', '..', 'scripts', 'extract-pdf.sh')` 는
# staging 에서는 `server/tools/../../scripts/extract-pdf.sh` = staging 루트 직하 scripts/
# parent repo 에서도 `mcp/tools/../../scripts/extract-pdf.sh` = tools/claude-brain/scripts/
# 이 계약이 깨지지 않았음을 확인 (ingest-pdf.mjs 에 경로 문자열이 남아있음)
grep -q "'..', '..', 'scripts', 'extract-pdf.sh'" "${REPO_ROOT}/tools/claude-brain/mcp/tools/ingest-pdf.mjs" \
  && pass "MCPB4b ingest-pdf.mjs 의 path resolve 가 scripts/ staging 배치와 정합" \
  || fail "MCPB4b ingest-pdf.mjs 의 path 문자열이 변경됨 — build-mcpb.sh 의 staging 위치와 재정합할 것"

# -----------------------------------------------------------------------------
# MCPB5: --clean removes build/ and dist/
# -----------------------------------------------------------------------------
echo "== MCPB5: --clean =="
set +e
out=$(bash "${BUILD_SCRIPT}" --clean 2>&1)
rc=$?
set -e
assert_eq "0" "${rc}" "MCPB5 exit code is 0"
[[ ! -d "${STAGING}" ]] && pass "MCPB5 staging removed" \
  || fail "MCPB5 staging still present"

# -----------------------------------------------------------------------------
# MCPB6-8: manifest.json sanity (independent of the build script)
# -----------------------------------------------------------------------------
echo "== MCPB6-8: manifest sanity =="
manifest_content="$(cat "${MANIFEST}")"
assert_contains "${manifest_content}" '"name": "gieok-wiki"' "MCPB6 manifest declares name=gieok-wiki"
assert_contains "${manifest_content}" '"vault_path"' "MCPB7 manifest defines vault_path user_config"
assert_contains "${manifest_content}" '"type": "directory"' "MCPB7 vault_path is directory picker"
assert_contains "${manifest_content}" '"OBSIDIAN_VAULT": "${user_config.vault_path}"' \
  "MCPB8 env wiring substitutes vault_path into OBSIDIAN_VAULT"

# -----------------------------------------------------------------------------
# 결과
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "build-mcpb tests:  ok=${PASS}  ng=${FAIL}"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
