#!/usr/bin/env bash
#
# setup-qmd.test.sh — scripts/setup-qmd.sh의 스모크 테스트 (Phase J)
#
# 실행: bash tools/claude-brain/tests/setup-qmd.test.sh
#
# 검증 항목:
#   J1  qmd 미설치 (PATH에 없음)                 -> exit 1 + 안내 메시지
#   J2a OBSIDIAN_VAULT 부재                       -> exit 1
#   J2  빈 Vault + stub qmd                       -> exit 0 + 3개 컬렉션 등록
#   J3  setup-qmd.sh를 2회 연속 실행 (멱등)       -> exit 0 + [exists]가 출력에 나타남
#   J4  GIEOK_QMD_SKIP_EMBED=1             -> qmd embed가 호출되지 않음

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SETUP_QMD="${REPO_ROOT}/tools/claude-brain/scripts/setup-qmd.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

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

# -----------------------------------------------------------------------------
# stub qmd: argv와 컬렉션 state를 파일에 남긴다.
#
# 상태:
#   ${QMD_STATE_DIR}/calls.log        — 호출 이력 (1줄 1 호출)
#   ${QMD_STATE_DIR}/collections.txt  — 등록된 컬렉션 이름 (1줄 1건)
#
# `collection add ... --name NAME ...`이 오면, NAME이 미등록이면 추가하고 exit 0,
# 이미 등록되어 있으면 exit 1 (실 qmd가 중복 시 비 0 종료하는 상정을 시뮬레이션).
# -----------------------------------------------------------------------------

STUB_DIR="${TMPROOT}/stub-bin"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/qmd" <<'STUB'
#!/usr/bin/env bash
set -e
LOG="${QMD_STATE_DIR}/calls.log"
STATE="${QMD_STATE_DIR}/collections.txt"
mkdir -p "${QMD_STATE_DIR}"
echo "qmd $*" >> "${LOG}"

case "${1:-}" in
  --version)
    echo "qmd-stub 0.0.0"
    exit 0
    ;;
  collection)
    case "${2:-}" in
      add)
        # Find --name argument
        name=""
        i=3
        while [[ $i -le $# ]]; do
          if [[ "${!i}" == "--name" ]]; then
            j=$((i + 1))
            name="${!j}"
            break
          fi
          i=$((i + 1))
        done
        if [[ -z "${name}" ]]; then
          exit 2
        fi
        if grep -q -F -x -- "${name}" "${STATE}" 2>/dev/null; then
          exit 1   # already exists
        fi
        echo "${name}" >> "${STATE}"
        exit 0
        ;;
      list)
        if [[ -f "${STATE}" ]]; then
          cat "${STATE}"
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;
  context|update|embed)
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/qmd"

# -----------------------------------------------------------------------------
# Vault 생성 헬퍼
# -----------------------------------------------------------------------------

make_vault() {
  local name="$1"
  local vault="${TMPROOT}/${name}"
  mkdir -p "${vault}/wiki" "${vault}/raw-sources" "${vault}/session-logs"
  echo "${vault}"
}

# -----------------------------------------------------------------------------
# Test J1: qmd 미설치 (PATH에 qmd 없음) -> exit 1 + 안내
# -----------------------------------------------------------------------------
echo "test J1: qmd not in PATH -> exit 1"
VAULT_J1="$(make_vault vault-j1)"
FAKE_HOME_J1="${TMPROOT}/fake-home-j1"
mkdir -p "${FAKE_HOME_J1}"
set +e
out_j1="$(
  env -i \
    HOME="${FAKE_HOME_J1}" \
    PATH="/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_J1}" \
    bash "${SETUP_QMD}" 2>&1
)"
rc=$?
set -e
assert_eq "1" "${rc}" "J1 exit code 1 when qmd missing"
assert_contains "${out_j1}" "qmd command not found" "J1 missing-qmd message present"
assert_contains "${out_j1}" "npm install -g @tobilu/qmd" "J1 install hint present"

# -----------------------------------------------------------------------------
# Test J2a: OBSIDIAN_VAULT 부재 -> exit 1
# -----------------------------------------------------------------------------
echo "test J2a: missing OBSIDIAN_VAULT -> exit 1"
set +e
(
  env -i \
    HOME="${TMPROOT}/fake-home-j2a" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    OBSIDIAN_VAULT="${TMPROOT}/does-not-exist-vault" \
    bash "${SETUP_QMD}" >/dev/null 2>&1
)
rc=$?
set -e
assert_eq "1" "${rc}" "J2a exit code 1 when vault missing"

# -----------------------------------------------------------------------------
# Test J2: 빈 Vault + stub qmd -> exit 0 + 3 collections registered
# -----------------------------------------------------------------------------
echo "test J2: fresh vault registers 2 collections (brain-logs opt-in)"
VAULT_J2="$(make_vault vault-j2)"
STATE_J2="${TMPROOT}/state-j2"
mkdir -p "${STATE_J2}"

set +e
out_j2="$(
  env -i \
    HOME="${TMPROOT}/fake-home-j2" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_J2}" \
    QMD_STATE_DIR="${STATE_J2}" \
    GIEOK_QMD_SKIP_EMBED=1 \
    bash "${SETUP_QMD}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "J2 exit code 0"
assert_contains "${out_j2}" "[added] brain-wiki"    "J2 brain-wiki added"
assert_contains "${out_j2}" "[added] brain-sources" "J2 brain-sources added"
assert_contains "${out_j2}" "[skip] brain-logs"     "J2 brain-logs skipped by default"
# 상태 파일에도 2개가 등록되었는지 (brain-logs는 기본값 비활성)
if [[ -f "${STATE_J2}/collections.txt" ]]; then
  count=$(wc -l < "${STATE_J2}/collections.txt" | tr -d ' ')
  assert_eq "2" "${count}" "J2 collections.txt has 2 entries"
else
  fail "J2 collections.txt was created"
fi

# J2b: --include-logs를 붙이면 brain-logs도 등록됨
echo "test J2b: --include-logs registers brain-logs"
VAULT_J2B="$(make_vault vault-j2b)"
STATE_J2B="${TMPROOT}/state-j2b"
mkdir -p "${STATE_J2B}"
set +e
out_j2b="$(
  env -i \
    HOME="${TMPROOT}/fake-home-j2b" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_J2B}" \
    QMD_STATE_DIR="${STATE_J2B}" \
    GIEOK_QMD_SKIP_EMBED=1 \
    bash "${SETUP_QMD}" --include-logs 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "J2b exit code 0"
assert_contains "${out_j2b}" "[added] brain-logs" "J2b brain-logs added with --include-logs"
count=$(wc -l < "${STATE_J2B}/collections.txt" | tr -d ' ')
assert_eq "3" "${count}" "J2b collections.txt has 3 entries"

# -----------------------------------------------------------------------------
# Test J3: 2회째 실행 -> 멱등 ([exists]로 표시)
# -----------------------------------------------------------------------------
echo "test J3: second run is idempotent"
set +e
out_j3="$(
  env -i \
    HOME="${TMPROOT}/fake-home-j2" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_J2}" \
    QMD_STATE_DIR="${STATE_J2}" \
    GIEOK_QMD_SKIP_EMBED=1 \
    bash "${SETUP_QMD}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "J3 exit code 0 on second run"
assert_contains "${out_j3}" "[exists] brain-wiki"    "J3 brain-wiki marked exists"
assert_contains "${out_j3}" "[exists] brain-sources" "J3 brain-sources marked exists"
assert_contains "${out_j3}" "[skip] brain-logs"      "J3 brain-logs still skipped by default"
# 상태는 변함없이 2건 유지
count=$(wc -l < "${STATE_J2}/collections.txt" | tr -d ' ')
assert_eq "2" "${count}" "J3 collections.txt still has 2 entries (no duplicates)"

# -----------------------------------------------------------------------------
# Test J4: GIEOK_QMD_SKIP_EMBED=1 -> qmd embed가 호출되지 않음
# -----------------------------------------------------------------------------
echo "test J4: skip embed flag prevents qmd embed call"
if grep -q "^qmd embed" "${STATE_J2}/calls.log" 2>/dev/null; then
  fail "J4 qmd embed should NOT be called when SKIP_EMBED=1"
else
  pass "J4 qmd embed was not called"
fi
# 반면 qmd update는 호출되어 있어야 함
if grep -q "^qmd update" "${STATE_J2}/calls.log" 2>/dev/null; then
  pass "J4 qmd update was called"
else
  fail "J4 qmd update should be called regardless of SKIP_EMBED"
fi

# -----------------------------------------------------------------------------
# 요약
# -----------------------------------------------------------------------------
echo
echo "==========================="
echo "  passed: ${PASS}"
echo "  failed: ${FAIL}"
echo "==========================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
