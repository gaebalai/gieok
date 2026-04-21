#!/usr/bin/env bash
#
# post-release-sync.test.sh — v0.4.0 post-release-sync.sh의 정적 검증
#
# 실행: bash tools/claude-brain/tests/post-release-sync.test.sh
#
# ## 배경
#
# post-release-sync.sh는 sync-to-app.sh 이후, gieok PR merge 뒤에 호출하여
# app/을 gieok 최신 main state에 맞추는 script. sync-to-app.test.sh와 달리
# 함수화되어 있지 않고 (main flow를 직접 기술하는 형태) 이므로 동적 실행 테스트가 아닌
# 정적 grep 검증으로 regression을 방지한다.
#
# 동적 smoke: `bash post-release-sync.sh --dry-run` 을 운영에서 돌려 담보한다.
#
# ## 검증 항목
#
#   PRS-S1  script 존재 + shebang + executable bit
#   PRS-S2  `set -euo pipefail` 선언 존재
#   PRS-S3  crash recovery guard (`.git`와 `.git-gieok` 둘 다 존재 시 abort)
#   PRS-S4  EXIT/INT/TERM/HUP trap에서 `.git → .git-gieok` 복원
#   PRS-S5  flag 분기 (`--commit` / `--dry-run` / `--help`) 존재
#   PRS-S6  bash -n syntax 건전성
#   PRS-S7  gieok main 맞춤 절차 (`git fetch origin` / `git checkout main` /
#           `git merge --ff-only origin/main`) 모두 포함
#   PRS-S8  --commit mode에서 `git add` / `git commit` / `git push origin main`
#           분기 존재
#   PRS-S9  --dry-run mode는 부작용 없음 (mv / git 계열 명령을 실행하지 않는 조기 exit)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TARGET="${REPO_ROOT}/tools/claude-brain/scripts/post-release-sync.sh"

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
# PRS-S1: 존재 + shebang + executable
# -----------------------------------------------------------------------------
echo "test PRS-S1: script exists, has shebang, is executable"

if [[ -f "${TARGET}" ]]; then
  pass "PRS-S1 script file exists"
else
  fail "PRS-S1 script not found at ${TARGET}"
  echo "FATAL: cannot continue" >&2
  exit 1
fi

if head -1 "${TARGET}" | grep -qE '^#!/usr/bin/env bash'; then
  pass "PRS-S1 shebang (#!/usr/bin/env bash) present"
else
  fail "PRS-S1 shebang missing or incorrect"
fi

if [[ -x "${TARGET}" ]]; then
  pass "PRS-S1 executable bit set"
else
  fail "PRS-S1 executable bit missing (chmod +x needed)"
fi

# -----------------------------------------------------------------------------
# PRS-S2: set -euo pipefail
# -----------------------------------------------------------------------------
echo "test PRS-S2: set -euo pipefail declared"

if grep -qE '^set -euo pipefail' "${TARGET}"; then
  pass "PRS-S2 set -euo pipefail present"
else
  fail "PRS-S2 set -euo pipefail missing"
fi

# -----------------------------------------------------------------------------
# PRS-S3: crash recovery guard
# -----------------------------------------------------------------------------
echo "test PRS-S3: crash recovery guard (.git + .git-gieok 둘 다 존재 시 abort)"

if grep -qE 'if \[\[ -d \.git && -d \.git-gieok \]\]' "${TARGET}"; then
  pass "PRS-S3 guard condition present"
else
  fail "PRS-S3 guard condition missing"
fi

if grep -qF "Manual recovery required" "${TARGET}"; then
  pass "PRS-S3 guard error message present"
else
  fail "PRS-S3 guard error message missing"
fi

# -----------------------------------------------------------------------------
# PRS-S4: EXIT trap에서 .git-gieok restore
# -----------------------------------------------------------------------------
echo "test PRS-S4: EXIT/INT/TERM/HUP trap에서 .git → .git-gieok 복원"

if grep -qE "trap '.*mv \.git \.git-gieok" "${TARGET}"; then
  pass "PRS-S4 trap command for restore present"
else
  fail "PRS-S4 trap command missing or malformed"
fi

if grep -qE 'trap .* EXIT INT TERM HUP' "${TARGET}"; then
  pass "PRS-S4 trap signals cover EXIT INT TERM HUP"
else
  fail "PRS-S4 trap signals incomplete"
fi

# -----------------------------------------------------------------------------
# PRS-S5: flag 분기 (--commit / --dry-run / --help)
# -----------------------------------------------------------------------------
echo "test PRS-S5: CLI flag branches"

for flag in '--commit' '--dry-run'; do
  if grep -qF -e "${flag})" "${TARGET}"; then
    pass "PRS-S5 flag ${flag} branch present"
  else
    fail "PRS-S5 flag ${flag} branch missing"
  fi
done

# --help 은 -h|--help 형식이면 OK (-F -e 로 flag 종료를 명시)
if grep -qF -e '-h|--help' "${TARGET}" || grep -qF -e '--help|-h' "${TARGET}"; then
  pass "PRS-S5 flag --help branch present"
else
  fail "PRS-S5 flag --help branch missing"
fi

# -----------------------------------------------------------------------------
# PRS-S6: bash -n syntax
# -----------------------------------------------------------------------------
echo "test PRS-S6: bash -n syntax check"

if bash -n "${TARGET}" 2>/dev/null; then
  pass "PRS-S6 bash -n syntax OK"
else
  fail "PRS-S6 bash -n syntax error"
fi

# -----------------------------------------------------------------------------
# PRS-S7: gieok main 맞춤 절차 (fetch → checkout → ff-only merge)
# -----------------------------------------------------------------------------
echo "test PRS-S7: gieok main alignment sequence"

if grep -qE 'git fetch origin' "${TARGET}"; then
  pass "PRS-S7 git fetch origin present"
else
  fail "PRS-S7 git fetch origin missing"
fi

if grep -qE 'git checkout main' "${TARGET}"; then
  pass "PRS-S7 git checkout main present"
else
  fail "PRS-S7 git checkout main missing"
fi

if grep -qE 'git merge --ff-only origin/main' "${TARGET}"; then
  pass "PRS-S7 git merge --ff-only origin/main present"
else
  fail "PRS-S7 git merge --ff-only origin/main missing"
fi

# -----------------------------------------------------------------------------
# PRS-S8: --commit mode 에서 git add / commit / push 분기
# -----------------------------------------------------------------------------
echo "test PRS-S8: --commit mode auto-commit sequence"

# --commit mode 안에 "git add tools/claude-brain/app/" / "git commit -m" /
# "git push origin main" 이 있을 것
if grep -qE 'git add tools/claude-brain/app/' "${TARGET}"; then
  pass "PRS-S8 git add tools/claude-brain/app/ present"
else
  fail "PRS-S8 git add command missing"
fi

if grep -qE 'git commit -m .*post-release app/ snapshot sync' "${TARGET}"; then
  pass "PRS-S8 git commit with descriptive message present"
else
  fail "PRS-S8 git commit message missing or malformed"
fi

if grep -qE 'git push origin main' "${TARGET}"; then
  pass "PRS-S8 git push origin main present"
else
  fail "PRS-S8 git push command missing"
fi

# -----------------------------------------------------------------------------
# PRS-S9: --dry-run mode는 조기 exit (부작용 없음)
# -----------------------------------------------------------------------------
echo "test PRS-S9: --dry-run exits before side effects"

# dry-run 섹션 내에서 trap / mv / git fetch 가 일어나지 않는지 확인
# (dry-run 분기의 exit 0 이 먼저 실행됨)
awk '
  /MODE == "dry-run"/ { flag=1 }
  flag { print }
  flag && /^exit 0$/ { exit }
' "${TARGET}" > /tmp/prs-dryrun-block.$$.txt

if [[ -s /tmp/prs-dryrun-block.$$.txt ]]; then
  if grep -qE '^mv \.git-gieok \.git' /tmp/prs-dryrun-block.$$.txt; then
    fail "PRS-S9 dry-run block contains actual mv (should be echo only)"
  else
    pass "PRS-S9 dry-run block performs no actual mv"
  fi

  if grep -qE '^git fetch origin' /tmp/prs-dryrun-block.$$.txt; then
    fail "PRS-S9 dry-run block contains actual git fetch (should be echo only)"
  else
    pass "PRS-S9 dry-run block performs no actual git fetch"
  fi
fi
rm -f /tmp/prs-dryrun-block.$$.txt

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
