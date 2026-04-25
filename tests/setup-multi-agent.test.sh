#!/usr/bin/env bash
#
# setup-multi-agent.test.sh — scripts/setup-multi-agent.sh 의 스모크 테스트
#
# 실행: bash tools/claude-brain/tests/setup-multi-agent.test.sh
#
# Test cases (v0.6 Phase C Task C-1):
#   SMA-1: 스크립트가 존재하고 문법적으로 유효함
#   SMA-2: skills/ 가 없으면 fatal error 로 exit 1
#   SMA-3: 최초 실행 시 3개 에이전트 (codex / opencode / gemini) 에 symlink 생성
#   SMA-4: 2회째 실행은 모두 [skip] (멱등성)
#   SMA-5: 기존 non-symlink 경로는 [WARN] 으로 skip (파괴하지 않음)
#   SMA-6: --uninstall 은 GIEOK 가 만든 symlink 만 제거
#   SMA-7: --agent=codex 로 대상 필터가 작동
#   SMA-8: --dry-run 은 실제로 symlink 를 만들지 않음
#
# 방침:
#   - HOME 환경 변수는 건드리지 않음. GIEOK_*_SKILLS_DIR env 로 target dir override
#   - mktemp -d 로 격리, trap 으로 cleanup
#   - bats 비의존, 자체 assert 함수만 사용

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SETUP_MULTI_AGENT="${REPO_ROOT}/tools/claude-brain/scripts/setup-multi-agent.sh"
SKILLS_SRC="${REPO_ROOT}/tools/claude-brain/skills"

if [[ ! -f "${SETUP_MULTI_AGENT}" ]]; then
  echo "FATAL: setup-multi-agent.sh not found at ${SETUP_MULTI_AGENT}" >&2
  exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

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

assert_symlink_to() {
  local link="$1"
  local expected_target="$2"
  local msg="$3"
  if [[ -L "${link}" ]]; then
    local actual
    actual="$(readlink "${link}")"
    if [[ "${actual}" == "${expected_target}" ]]; then
      pass "${msg}"
    else
      fail "${msg} (expected->${expected_target}, actual->${actual})"
    fi
  else
    fail "${msg} (not a symlink: ${link})"
  fi
}

assert_not_exists() {
  local path="$1"
  local msg="$2"
  if [[ ! -e "${path}" && ! -L "${path}" ]]; then
    pass "${msg}"
  else
    fail "${msg} (path still exists: ${path})"
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "${expected}" -eq "${actual}" ]]; then
    pass "${msg}"
  else
    fail "${msg} (expected exit=${expected}, actual=${actual})"
  fi
}

# 헬퍼: 격리된 tmp agent skill root 를 만들어 script 를 호출
run_setup_multi_agent() {
  local codex_dir="$1"; shift
  local opencode_dir="$1"; shift
  local gemini_dir="$1"; shift
  GIEOK_CODEX_SKILLS_DIR="${codex_dir}" \
  GIEOK_OPENCODE_SKILLS_DIR="${opencode_dir}" \
  GIEOK_GEMINI_SKILLS_DIR="${gemini_dir}" \
  bash "${SETUP_MULTI_AGENT}" "$@"
}

# =========================================================================
# SMA-1: 스크립트가 실행 가능
# =========================================================================
echo "--- SMA-1: script exists and is syntactically valid ---"
bash -n "${SETUP_MULTI_AGENT}" && pass "bash -n syntax check" || fail "bash -n syntax check failed"

# =========================================================================
# SMA-3: 최초 실행으로 3개 에이전트에 symlink 생성
# =========================================================================
echo "--- SMA-3: initial install creates 3 symlinks ---"
T3="${TMPROOT}/sma3"
run_setup_multi_agent "${T3}/codex" "${T3}/opencode" "${T3}/gemini" > /dev/null
assert_symlink_to "${T3}/codex/gieok" "${SKILLS_SRC}" "codex symlink created"
assert_symlink_to "${T3}/opencode/gieok" "${SKILLS_SRC}" "opencode symlink created"
assert_symlink_to "${T3}/gemini/gieok" "${SKILLS_SRC}" "gemini symlink created"

# =========================================================================
# SMA-4: 2회째 실행은 멱등 (모두 [skip])
# =========================================================================
echo "--- SMA-4: second run is idempotent ---"
out_second=$(run_setup_multi_agent "${T3}/codex" "${T3}/opencode" "${T3}/gemini" 2>&1)
if echo "${out_second}" | grep -qE "created=0.*skipped=3"; then
  pass "second run: created=0 skipped=3"
else
  fail "second run not idempotent (got: $(echo "${out_second}" | grep "created="))"
fi

# =========================================================================
# SMA-5: 기존 non-symlink 경로는 [WARN] 으로 skip
# =========================================================================
echo "--- SMA-5: existing non-symlink path is skipped with WARN ---"
T5="${TMPROOT}/sma5"
mkdir -p "${T5}/codex"
# 기존 일반 디렉터리를 생성 (symlink 아님)
mkdir "${T5}/codex/gieok"
out5=$(run_setup_multi_agent "${T5}/codex" "${T5}/opencode" "${T5}/gemini" 2>&1 || true)
if echo "${out5}" | grep -q "WARN.*codex.*not a symlink"; then
  pass "non-symlink path triggers WARN"
else
  fail "non-symlink WARN not emitted (got: ${out5})"
fi
# 기존 디렉터리가 파괴되지 않았는지 확인
if [[ -d "${T5}/codex/gieok" && ! -L "${T5}/codex/gieok" ]]; then
  pass "existing directory not clobbered"
else
  fail "existing directory was clobbered"
fi

# =========================================================================
# SMA-6: --uninstall 은 GIEOK symlink 만 제거
# =========================================================================
echo "--- SMA-6: --uninstall removes only GIEOK-created symlinks ---"
T6="${TMPROOT}/sma6"
# install
run_setup_multi_agent "${T6}/codex" "${T6}/opencode" "${T6}/gemini" > /dev/null
# 다른 target 을 가리키는 symlink 를 수동으로 생성 (GIEOK 가 만든 것이 아님)
mkdir -p "${T6}/other"
ln -sfn "${TMPROOT}" "${T6}/other/gieok"
# uninstall (--uninstall 플래그)
run_setup_multi_agent "${T6}/codex" "${T6}/opencode" "${T6}/gemini" --uninstall > /dev/null
# GIEOK symlinks 는 사라졌다
assert_not_exists "${T6}/codex/gieok" "uninstall: codex symlink removed"
assert_not_exists "${T6}/opencode/gieok" "uninstall: opencode symlink removed"
assert_not_exists "${T6}/gemini/gieok" "uninstall: gemini symlink removed"
# 관계 없는 symlink 는 건드리지 않음
if [[ -L "${T6}/other/gieok" ]]; then
  pass "uninstall: unrelated symlink not touched"
else
  fail "uninstall: unrelated symlink was deleted"
fi

# =========================================================================
# SMA-7: --agent=codex 로 filter 작동
# =========================================================================
echo "--- SMA-7: --agent filter limits target ---"
T7="${TMPROOT}/sma7"
run_setup_multi_agent "${T7}/codex" "${T7}/opencode" "${T7}/gemini" --agent=codex > /dev/null
assert_symlink_to "${T7}/codex/gieok" "${SKILLS_SRC}" "agent=codex: codex linked"
assert_not_exists "${T7}/opencode/gieok" "agent=codex: opencode NOT linked"
assert_not_exists "${T7}/gemini/gieok" "agent=codex: gemini NOT linked"

# =========================================================================
# SMA-8: --dry-run 은 실제로 symlink 를 만들지 않음
# =========================================================================
echo "--- SMA-8: --dry-run does not create symlinks ---"
T8="${TMPROOT}/sma8"
out8=$(run_setup_multi_agent "${T8}/codex" "${T8}/opencode" "${T8}/gemini" --dry-run 2>&1)
if echo "${out8}" | grep -q "DRY RUN"; then
  pass "dry-run: banner emitted"
else
  fail "dry-run: banner not emitted"
fi
assert_not_exists "${T8}/codex/gieok" "dry-run: no symlink created (codex)"
assert_not_exists "${T8}/opencode/gieok" "dry-run: no symlink created (opencode)"
assert_not_exists "${T8}/gemini/gieok" "dry-run: no symlink created (gemini)"

# =========================================================================
# SMA-2: skills/ 부재로 fatal error (마지막에 실행, SKILLS_SRC 를 일시적으로 숨김)
# =========================================================================
echo "--- SMA-2: missing skills/ src exits 1 ---"
# skills/ 없는 별도 repo-like tempdir 를 생성해 script 를 복사 실행
T2="${TMPROOT}/sma2-repo"
mkdir -p "${T2}/tools/claude-brain/scripts"
cp "${SETUP_MULTI_AGENT}" "${T2}/tools/claude-brain/scripts/setup-multi-agent.sh"
set +e
(bash "${T2}/tools/claude-brain/scripts/setup-multi-agent.sh" > /dev/null 2>&1)
rc=$?
set -e
assert_exit_code 1 "${rc}" "skills/ missing: exit 1"

# =========================================================================
# Summary
# =========================================================================
echo
echo "===================="
echo "PASS=${PASS} FAIL=${FAIL}"
echo "===================="
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
