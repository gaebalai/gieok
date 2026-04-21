#!/usr/bin/env bash
#
# sync-to-app.test.sh — v0.4.0 Tier B#3 GitHub-side lock (α) 의 테스트
#
# 실행: bash tools/claude-brain/tests/sync-to-app.test.sh
#
# ## 배경
#
# 2대 운용 (MacBook + Mac mini) 에서 cron sync가 근접한 시각에 기동되면, 양쪽이
# 동일한 내용으로 origin/next에 push 해서 중복 PR 이 생기는 race 조건이 있다 (증상 #1).
# α = GitHub-side lock: `gh api branches/next` 로 최종 push 시각을 확인하고, 임계값
# 이내면 조기 exit (scripts/sync-to-app.sh 의 check_github_side_lock).
#
# 합의 기록: plan/claude/26042104_meeting_v0-4-0-sync-to-app-race-fix.md
#           ## Resume session 2 — 2026-04-21
#
# ## 검증 항목 (동적: 함수를 추출하여 직접 호출)
#
#   SYN-R1  gh가 now timestamp → 조기 exit (skip 메시지 포함)
#   SYN-R1b gh가 old timestamp → return 0 (proceed, REACHED_END 도달)
#   SYN-R1c gh 명령 실패 → return 0 (fail-open)
#   SYN-R5  DRY_RUN=1 → return 0 (dry-run에서 lock skip)
#   SYN-R6  GIEOK_SYNC_LOCK_MAX_AGE=0 → return 0 (env로 무효화)
#
# ## 검증 항목 (정적: script 본체의 구조 regression 방지)
#
#   SYN-S1  check_github_side_lock() 함수가 sync-to-app.sh 에 정의되어 있음
#   SYN-S2  함수 호출이 `git fetch origin` 직후 (fetch → checkout 사이)
#   SYN-S3  기존 trap (.git-gieok restore) 이 훼손되지 않음
#   SYN-S4  GIEOK_SYNC_LOCK_MAX_AGE의 env 참조와 DRY_RUN 체크가 존재
#
# ## 설계 메모
#
# 함수를 subshell에서 호출하면, exit 0 은 subshell 종료 / return 0 은 뒤이은 echo 실행
# 으로 동작 차이를 관측할 수 있다 (REACHED_END sentinel). rsync / git scaffold 를 피하는
# 가벼운 패턴. full-flow integration은 2대 실기 smoke에 위임.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TOOL_ROOT="${REPO_ROOT}/tools/claude-brain"
TARGET="${TOOL_ROOT}/scripts/sync-to-app.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

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

# -----------------------------------------------------------------------------
# SYN-S1: 함수 정의 존재 확인 + extract
# -----------------------------------------------------------------------------
echo "test SYN-S1: check_github_side_lock() definition exists in sync-to-app.sh"

if [[ ! -f "${TARGET}" ]]; then
  fail "SYN-S1 sync-to-app.sh not found at ${TARGET}"
  echo "FATAL: cannot continue without target script" >&2
  exit 1
fi

# awk로 함수 정의 (최초의 `}` 까지) 를 잘라낸다. 함수 안에 nested brace가 없다고 가정.
fn_def="$(awk '
  /^check_github_side_lock\(\) \{/ { flag=1 }
  flag { print }
  flag && /^}$/ { exit }
' "${TARGET}")"

if [[ -z "${fn_def}" ]]; then
  fail "SYN-S1 check_github_side_lock() definition not found in ${TARGET}"
  echo "FATAL: cannot continue without function definition" >&2
  exit 1
else
  pass "SYN-S1 function definition extracted ($(printf '%s' "${fn_def}" | wc -l | tr -d ' ') lines)"
fi

# test shell에 함수를 적재
eval "${fn_def}"

# -----------------------------------------------------------------------------
# SYN-S2: 함수 호출이 git fetch 직후 (fetch → checkout 사이) 에 있음
# -----------------------------------------------------------------------------
echo "test SYN-S2: check_github_side_lock is invoked between fetch and checkout"

# `git fetch origin --quiet` 행의 다음에 있는 (빈 줄/주석 끼워넣어도 OK) 몇 줄 안에
# `check_github_side_lock` 이 있고, 나아가 그것이 `git checkout -B next origin/main`
# 보다 앞에 있음을 확인.
fetch_line="$(grep -n '^git fetch origin --quiet' "${TARGET}" | head -1 | cut -d: -f1)"
call_line="$(grep -n '^check_github_side_lock$' "${TARGET}" | head -1 | cut -d: -f1)"
checkout_line="$(grep -n 'git checkout -B next origin/main' "${TARGET}" | head -1 | cut -d: -f1)"

if [[ -z "${fetch_line}" ]]; then
  fail "SYN-S2 'git fetch origin --quiet' not found"
elif [[ -z "${call_line}" ]]; then
  fail "SYN-S2 'check_github_side_lock' call site not found"
elif [[ -z "${checkout_line}" ]]; then
  fail "SYN-S2 'git checkout -B next origin/main' not found"
elif (( call_line > fetch_line && call_line < checkout_line )); then
  pass "SYN-S2 call position ok (fetch@${fetch_line} < call@${call_line} < checkout@${checkout_line})"
else
  fail "SYN-S2 call position wrong (fetch@${fetch_line}, call@${call_line}, checkout@${checkout_line})"
fi

# -----------------------------------------------------------------------------
# SYN-S3: 기존 trap chain (.git-gieok restore) 비파괴
# -----------------------------------------------------------------------------
echo "test SYN-S3: existing trap for .git-gieok restore is preserved"

if grep -qE "trap .*mv \.git \.git-gieok.* EXIT INT TERM HUP" "${TARGET}"; then
  pass "SYN-S3 trap line for .git-gieok restore intact"
else
  fail "SYN-S3 trap for .git-gieok restore not found or malformed (regression?)"
fi

# -----------------------------------------------------------------------------
# SYN-S4: GIEOK_SYNC_LOCK_MAX_AGE env와 DRY_RUN skip 참조가 함수 내에 존재
# -----------------------------------------------------------------------------
echo "test SYN-S4: env-var hooks inside check_github_side_lock"

if printf '%s' "${fn_def}" | grep -qE 'GIEOK_SYNC_LOCK_MAX_AGE'; then
  pass "SYN-S4 GIEOK_SYNC_LOCK_MAX_AGE env reference present"
else
  fail "SYN-S4 GIEOK_SYNC_LOCK_MAX_AGE env reference missing"
fi

if printf '%s' "${fn_def}" | grep -qE 'DRY_RUN.*== .1.'; then
  pass "SYN-S4 DRY_RUN=1 skip branch present"
else
  fail "SYN-S4 DRY_RUN=1 skip branch missing"
fi

# -----------------------------------------------------------------------------
# 동적 테스트용 gh stub 준비
# -----------------------------------------------------------------------------
# 동일한 stub 바이너리를 3 모드 (now / old / fail) 로 사용 구분하기 위해, mode 를
# 파일 (STUB_MODE_FILE) 로 동적으로 전환한다.
STUB_MODE_FILE="${TMP}/gh-mode"
export STUB_MODE_FILE

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub for sync-to-app.test.sh
# STUB_MODE_FILE로 동작 선택 (now/old/fail)
mode="unset"
if [[ -n "${STUB_MODE_FILE:-}" && -f "${STUB_MODE_FILE}" ]]; then
  mode="$(cat "${STUB_MODE_FILE}")"
fi
case "${mode}" in
  now)
    # 현재 UTC ISO-8601 (lock 이 적용되는 신선한 push)
    date -u +%Y-%m-%dT%H:%M:%SZ
    ;;
  old)
    # 1시간 전 (임계값 120s 보다 충분히 오래됨 → proceed)
    # macOS (BSD) 와 Linux (GNU) 양쪽에서 동작하도록 두 구문을 시도
    if out="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
      echo "${out}"
    else
      date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ
    fi
    ;;
  fail)
    # gh auth 끊김 / network error 상당
    exit 1
    ;;
  *)
    echo "gh stub: mode '${mode}' not set" >&2
    exit 1
    ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# PATH 선두에 stub을 주입. real gh가 시스템에 있어도 이쪽이 우선된다.
export PATH="${TMP}/bin:${PATH}"

# -----------------------------------------------------------------------------
# 동적 테스트 헬퍼: subshell에서 함수 호출, exit/return 을 REACHED_END 로 판정
# -----------------------------------------------------------------------------
# exit 0 → subshell 종료, REACHED_END 나오지 않음
# return 0 → 뒤이은 echo 실행, REACHED_END 나옴
# stdout/stderr 는 2>&1 으로 머지해 일괄 관측.
call_and_capture() {
  ( check_github_side_lock 2>&1; echo "REACHED_END" )
}

# -----------------------------------------------------------------------------
# SYN-R1: gh가 now timestamp → 조기 exit (skip 메시지)
# -----------------------------------------------------------------------------
echo "test SYN-R1: exits early when origin/next was just pushed"
echo "now" > "${STUB_MODE_FILE}"
unset DRY_RUN GIEOK_SYNC_LOCK_MAX_AGE
out="$(call_and_capture)"

if echo "${out}" | grep -q "REACHED_END"; then
  fail "SYN-R1 function returned instead of exiting (output: ${out})"
else
  pass "SYN-R1 function exited early (REACHED_END not emitted)"
fi

if echo "${out}" | grep -qF '[skip] origin/next was pushed'; then
  pass "SYN-R1 skip message emitted to stderr"
else
  fail "SYN-R1 skip message not found (output: ${out})"
fi

# -----------------------------------------------------------------------------
# SYN-R1b: gh가 old timestamp → return 0 (proceed)
# -----------------------------------------------------------------------------
echo "test SYN-R1b: proceeds when origin/next push is stale (>threshold)"
echo "old" > "${STUB_MODE_FILE}"
unset DRY_RUN GIEOK_SYNC_LOCK_MAX_AGE
out="$(call_and_capture)"

if echo "${out}" | grep -q "REACHED_END"; then
  pass "SYN-R1b function returned (script would proceed to checkout)"
else
  fail "SYN-R1b function exited but was expected to proceed (output: ${out})"
fi

# -----------------------------------------------------------------------------
# SYN-R1c: gh가 실패 → fail-open (proceed)
# -----------------------------------------------------------------------------
echo "test SYN-R1c: fails open when gh returns non-zero (auth/network error)"
echo "fail" > "${STUB_MODE_FILE}"
unset DRY_RUN GIEOK_SYNC_LOCK_MAX_AGE
out="$(call_and_capture)"

if echo "${out}" | grep -q "REACHED_END"; then
  pass "SYN-R1c function fail-open succeeded (proceed despite gh error)"
else
  fail "SYN-R1c function exited when it should fail-open (output: ${out})"
fi

# -----------------------------------------------------------------------------
# SYN-R5: DRY_RUN=1 → 즉시 return 0 (gh 호출 없이)
# -----------------------------------------------------------------------------
echo "test SYN-R5: --dry-run skips lock check without calling gh"
# gh를 "now" 모드로 설정: 만약 gh가 호출되었다면 SYN-R1 과 같은 skip exit 이 된다.
# REACHED_END 가 나오면 DRY_RUN 분기에서 조기 return 할 수 있다는 증거.
echo "now" > "${STUB_MODE_FILE}"
unset GIEOK_SYNC_LOCK_MAX_AGE
out="$(
  export DRY_RUN=1
  check_github_side_lock 2>&1
  echo "REACHED_END"
)"

if echo "${out}" | grep -q "REACHED_END"; then
  pass "SYN-R5 function returned early under DRY_RUN=1"
else
  fail "SYN-R5 function exited despite DRY_RUN=1 (output: ${out})"
fi

# -----------------------------------------------------------------------------
# SYN-R6: GIEOK_SYNC_LOCK_MAX_AGE=0 → guard 무효화 (proceed)
# -----------------------------------------------------------------------------
echo "test SYN-R6: GIEOK_SYNC_LOCK_MAX_AGE=0 disables the guard"
echo "now" > "${STUB_MODE_FILE}"
unset DRY_RUN
out="$(
  export GIEOK_SYNC_LOCK_MAX_AGE=0
  check_github_side_lock 2>&1
  echo "REACHED_END"
)"

if echo "${out}" | grep -q "REACHED_END"; then
  pass "SYN-R6 function returned early with GIEOK_SYNC_LOCK_MAX_AGE=0"
else
  fail "SYN-R6 function exited despite GIEOK_SYNC_LOCK_MAX_AGE=0 (output: ${out})"
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
