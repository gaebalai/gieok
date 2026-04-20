#!/usr/bin/env bash
#
# install-launchagents.test.sh — scripts/install-launchagents.sh 스모크 테스트 (Phase L)
#
# 실행: bash tools/claude-brain/tests/install-launchagents.test.sh
#
# 검증 항목:
#   LA1 최초 실행으로 2개의 plist 가 생성됨 (ingest + lint)
#   LA2 2회차 실행에서 둘 다 [skip] 이 됨 (멱등)
#   LA3 plist 내에 플레이스홀더 (__FOO__) 가 남아있지 않음
#   LA4 내용이 다른 기존 plist 가 먼저 있으면 WARN + exit 2
#   LA5 --force 로 기존 plist 를 덮어쓰기
#   LA6 --dry-run 으로 plist 가 생성되지 않음
#   LA7 OBSIDIAN_VAULT 미설정 → exit 1
#   LA8 --uninstall 로 plist 가 삭제됨
#
# 실제 $HOME/Library/LaunchAgents 는 절대 건드리지 않음:
#   - CLAUDE_LAUNCHAGENTS_DIR 를 mktemp 위치로 교체
#   - GIEOK_SKIP_LOAD=1 로 launchctl bootstrap/bootout 을 스킵

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/tools/claude-brain/scripts/install-launchagents.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

FAKE_VAULT="${TMPROOT}/fake-vault"
mkdir -p "${FAKE_VAULT}"

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

run_install() {
  local dest="$1"
  shift
  local out rc
  set +e
  out=$(
    CLAUDE_LAUNCHAGENTS_DIR="${dest}" \
    GIEOK_SKIP_LOAD=1 \
    OBSIDIAN_VAULT="${FAKE_VAULT}" \
    bash "${INSTALL_SCRIPT}" "$@" 2>&1
  )
  rc=$?
  set -e
  printf '%s\n' "${out}"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# LA1 / LA2 / LA3: 최초 생성 → 멱등 재실행 → 플레이스홀더 잔존 체크
# -----------------------------------------------------------------------------
echo "== LA1/LA2/LA3: create, idempotent, no unresolved placeholders =="

DEST1="${TMPROOT}/dest1"
out1=$(run_install "${DEST1}")
rc1=$?
assert_eq "0" "${rc1}" "LA1: first run exits 0"
assert_contains "${out1}" "[create]  com.gieok.ingest.plist" "LA1: ingest plist created"
assert_contains "${out1}" "[create]  com.gieok.lint.plist" "LA1: lint plist created"

INGEST_PLIST="${DEST1}/com.gieok.ingest.plist"
LINT_PLIST="${DEST1}/com.gieok.lint.plist"

if [[ -f "${INGEST_PLIST}" ]]; then
  pass "LA1: ingest plist file exists"
else
  fail "LA1: ingest plist file missing"
fi
if [[ -f "${LINT_PLIST}" ]]; then
  pass "LA1: lint plist file exists"
else
  fail "LA1: lint plist file missing"
fi

# LA3: 플레이스홀더가 남아있지 않을 것
if ! grep -q '__[A-Z_]*__' "${INGEST_PLIST}"; then
  pass "LA3: no placeholders in ingest plist"
else
  fail "LA3: placeholders still present in ingest plist"
fi
if ! grep -q '__[A-Z_]*__' "${LINT_PLIST}"; then
  pass "LA3: no placeholders in lint plist"
else
  fail "LA3: placeholders still present in lint plist"
fi

# Vault 경로가 올바르게 삽입되어 있을 것
if grep -q -F "${FAKE_VAULT}" "${INGEST_PLIST}"; then
  pass "LA3: OBSIDIAN_VAULT embedded in ingest plist"
else
  fail "LA3: OBSIDIAN_VAULT not found in ingest plist"
fi

# Label 이 올바를 것
if grep -q -F "<string>com.gieok.ingest</string>" "${INGEST_PLIST}"; then
  pass "LA3: Label correct in ingest plist"
else
  fail "LA3: Label incorrect in ingest plist"
fi

# LA2: 2회차 실행은 skip
out2=$(run_install "${DEST1}")
rc2=$?
assert_eq "0" "${rc2}" "LA2: second run exits 0"
assert_contains "${out2}" "[skip]    com.gieok.ingest.plist" "LA2: ingest plist skipped"
assert_contains "${out2}" "[skip]    com.gieok.lint.plist" "LA2: lint plist skipped"

# -----------------------------------------------------------------------------
# LA4: 내용이 다른 기존 plist → WARN + exit 2
# -----------------------------------------------------------------------------
echo "== LA4: differing existing plist blocks install =="

DEST4="${TMPROOT}/dest4"
mkdir -p "${DEST4}"
echo "<!-- prior garbage -->" > "${DEST4}/com.gieok.ingest.plist"

set +e
out4=$(
  CLAUDE_LAUNCHAGENTS_DIR="${DEST4}" \
  GIEOK_SKIP_LOAD=1 \
  OBSIDIAN_VAULT="${FAKE_VAULT}" \
  bash "${INSTALL_SCRIPT}" 2>&1
)
rc4=$?
set -e

assert_eq "2" "${rc4}" "LA4: exit 2 when plist differs without --force"
assert_contains "${out4}" "[WARN]" "LA4: WARN printed"
assert_contains "${out4}" "--force" "LA4: --force hint included"

# 기존 파일이 보존되어 있음 (덮어쓰지 않음)
content4="$(cat "${DEST4}/com.gieok.ingest.plist")"
assert_eq "<!-- prior garbage -->" "${content4}" "LA4: existing file preserved"

# -----------------------------------------------------------------------------
# LA5: --force 로 덮어쓰기
# -----------------------------------------------------------------------------
echo "== LA5: --force overwrites differing plist =="

DEST5="${TMPROOT}/dest5"
mkdir -p "${DEST5}"
echo "old stuff" > "${DEST5}/com.gieok.ingest.plist"

out5=$(run_install "${DEST5}" --force)
rc5=$?
assert_eq "0" "${rc5}" "LA5: --force run exits 0"
assert_contains "${out5}" "[force]" "LA5: [force] marker printed"

# 내용이 plist 형식으로 교체되어 있을 것
if grep -q -F "com.gieok.ingest" "${DEST5}/com.gieok.ingest.plist"; then
  pass "LA5: content replaced with real plist"
else
  fail "LA5: content not replaced"
fi

# -----------------------------------------------------------------------------
# LA6: --dry-run 은 아무것도 쓰지 않음
# -----------------------------------------------------------------------------
echo "== LA6: --dry-run writes nothing =="

DEST6="${TMPROOT}/dest6-does-not-exist"
out6=$(run_install "${DEST6}" --dry-run)
rc6=$?
assert_eq "0" "${rc6}" "LA6: --dry-run exits 0"
assert_contains "${out6}" "DRY RUN" "LA6: DRY RUN marker printed"

if [[ ! -f "${DEST6}/com.gieok.ingest.plist" ]]; then
  pass "LA6: ingest plist not created on dry run"
else
  fail "LA6: ingest plist created on dry run"
fi
if [[ ! -f "${DEST6}/com.gieok.lint.plist" ]]; then
  pass "LA6: lint plist not created on dry run"
else
  fail "LA6: lint plist created on dry run"
fi

# -----------------------------------------------------------------------------
# LA7: OBSIDIAN_VAULT 미설정 → exit 1
# -----------------------------------------------------------------------------
echo "== LA7: missing OBSIDIAN_VAULT fails =="

DEST7="${TMPROOT}/dest7"
set +e
out7=$(
  env -i \
    HOME="${HOME}" \
    PATH="/usr/bin:/bin" \
    CLAUDE_LAUNCHAGENTS_DIR="${DEST7}" \
    GIEOK_SKIP_LOAD=1 \
    bash "${INSTALL_SCRIPT}" 2>&1
)
rc7=$?
set -e

assert_eq "1" "${rc7}" "LA7: exit 1 when OBSIDIAN_VAULT unset"
assert_contains "${out7}" "OBSIDIAN_VAULT" "LA7: error mentions OBSIDIAN_VAULT"

# -----------------------------------------------------------------------------
# LA8: --uninstall 로 plist 삭제
# -----------------------------------------------------------------------------
echo "== LA8: --uninstall removes plists =="

DEST8="${TMPROOT}/dest8"
out8a=$(run_install "${DEST8}")
rc8a=$?
assert_eq "0" "${rc8a}" "LA8: install before uninstall exits 0"

if [[ -f "${DEST8}/com.gieok.ingest.plist" ]]; then
  pass "LA8: plist exists before uninstall"
else
  fail "LA8: plist missing before uninstall"
fi

out8b=$(run_install "${DEST8}" --uninstall)
rc8b=$?
assert_eq "0" "${rc8b}" "LA8: --uninstall exits 0"
assert_contains "${out8b}" "[removed]" "LA8: [removed] marker printed"

if [[ ! -f "${DEST8}/com.gieok.ingest.plist" ]]; then
  pass "LA8: ingest plist removed"
else
  fail "LA8: ingest plist still present after uninstall"
fi
if [[ ! -f "${DEST8}/com.gieok.lint.plist" ]]; then
  pass "LA8: lint plist removed"
else
  fail "LA8: lint plist still present after uninstall"
fi

# -----------------------------------------------------------------------------
echo
echo "install-launchagents tests: PASS=${PASS} FAIL=${FAIL}"
if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
