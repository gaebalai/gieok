#!/usr/bin/env bash
#
# install-skills.test.sh — scripts/install-skills.sh 스모크 테스트
#
# 실행: bash tools/claude-brain/tests/install-skills.test.sh
#
# 검증 항목:
#   IS1 최초 실행으로 wiki-ingest-all 과 wiki-ingest 의 2개 symlink 가 생성됨
#   IS2 2회차 실행에서 둘 다 [skip] 이 됨 (멱등)
#   IS3 symlink 의 링크 대상이 실제 repo skills/ 를 가리킴
#   IS4 비 symlink (일반 파일) 가 먼저 있으면 WARN + exit 2 (--force 없음)
#   IS5 --force 로 비 symlink 를 덮어쓰기
#   IS6 --dry-run 으로 대상이 생성되지 않음
#   IS7 대상 디렉터리가 존재하지 않아도 자동 생성됨

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/tools/claude-brain/scripts/install-skills.sh"
SKILLS_SRC="${REPO_ROOT}/tools/claude-brain/skills"

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
  out=$(CLAUDE_SKILLS_DIR="${dest}" bash "${INSTALL_SCRIPT}" "$@" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "${out}"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# IS1 / IS2 / IS3: 최초 생성 → 멱등 재실행 → 링크 대상 검증
# -----------------------------------------------------------------------------
echo "== IS1/IS2/IS3: create, idempotent, link target =="

DEST1="${TMPROOT}/dest1"
out1=$(run_install "${DEST1}")
rc1=$?
assert_eq "0" "${rc1}" "IS1: first run exits 0"
assert_contains "${out1}" "[create]  wiki-ingest-all" "IS1: wiki-ingest-all created"
assert_contains "${out1}" "[create]  wiki-ingest" "IS1: wiki-ingest created"

# symlink 일 것
if [[ -L "${DEST1}/wiki-ingest-all" ]]; then
  pass "IS1: wiki-ingest-all is a symlink"
else
  fail "IS1: wiki-ingest-all is not a symlink"
fi
if [[ -L "${DEST1}/wiki-ingest" ]]; then
  pass "IS1: wiki-ingest is a symlink"
else
  fail "IS1: wiki-ingest is not a symlink"
fi

# IS3: 링크 대상이 repo skills/ 를 가리킴
target_all="$(readlink "${DEST1}/wiki-ingest-all")"
target_one="$(readlink "${DEST1}/wiki-ingest")"
assert_eq "${SKILLS_SRC}/wiki-ingest-all" "${target_all}" "IS3: wiki-ingest-all target matches repo"
assert_eq "${SKILLS_SRC}/wiki-ingest" "${target_one}" "IS3: wiki-ingest target matches repo"

# 링크 대상의 SKILL.md 를 실제로 읽을 수 있음
if [[ -f "${DEST1}/wiki-ingest-all/SKILL.md" ]]; then
  pass "IS3: SKILL.md reachable via wiki-ingest-all symlink"
else
  fail "IS3: SKILL.md not reachable via wiki-ingest-all symlink"
fi

# IS2: 2회차 실행은 skip
out2=$(run_install "${DEST1}")
rc2=$?
assert_eq "0" "${rc2}" "IS2: second run exits 0"
assert_contains "${out2}" "[skip]    wiki-ingest-all" "IS2: wiki-ingest-all skipped on rerun"
assert_contains "${out2}" "[skip]    wiki-ingest" "IS2: wiki-ingest skipped on rerun"

# -----------------------------------------------------------------------------
# IS4: 비 symlink 가 먼저 있으면 WARN + exit 2
# -----------------------------------------------------------------------------
echo "== IS4: existing non-symlink file blocks install =="

DEST4="${TMPROOT}/dest4"
mkdir -p "${DEST4}"
# 기존 일반 파일을 배치
echo "prior content" > "${DEST4}/wiki-ingest-all"

set +e
out4=$(CLAUDE_SKILLS_DIR="${DEST4}" bash "${INSTALL_SCRIPT}" 2>&1)
rc4=$?
set -e

assert_eq "2" "${rc4}" "IS4: exit 2 when non-symlink exists without --force"
assert_contains "${out4}" "[WARN]" "IS4: WARN printed"
assert_contains "${out4}" "--force" "IS4: --force hint included"

# 기존 파일이 보존됨
if [[ -f "${DEST4}/wiki-ingest-all" ]] && ! [[ -L "${DEST4}/wiki-ingest-all" ]]; then
  content="$(cat "${DEST4}/wiki-ingest-all")"
  assert_eq "prior content" "${content}" "IS4: existing file preserved"
else
  fail "IS4: existing file was altered"
fi

# -----------------------------------------------------------------------------
# IS5: --force 로 덮어쓰기
# -----------------------------------------------------------------------------
echo "== IS5: --force overwrites non-symlink =="

DEST5="${TMPROOT}/dest5"
mkdir -p "${DEST5}"
echo "old stuff" > "${DEST5}/wiki-ingest-all"

out5=$(run_install "${DEST5}" --force)
rc5=$?
assert_eq "0" "${rc5}" "IS5: --force run exits 0"
assert_contains "${out5}" "[force]" "IS5: [force] marker printed"

if [[ -L "${DEST5}/wiki-ingest-all" ]]; then
  pass "IS5: wiki-ingest-all is now a symlink"
else
  fail "IS5: wiki-ingest-all is still a regular file"
fi

# -----------------------------------------------------------------------------
# IS6: --dry-run 은 대상을 만들지 않음
# -----------------------------------------------------------------------------
echo "== IS6: --dry-run writes nothing =="

DEST6="${TMPROOT}/dest6-does-not-exist"
out6=$(run_install "${DEST6}" --dry-run)
rc6=$?
assert_eq "0" "${rc6}" "IS6: --dry-run exits 0"
assert_contains "${out6}" "DRY RUN" "IS6: DRY RUN marker printed"

if [[ ! -e "${DEST6}" ]]; then
  pass "IS6: destination not created on dry run"
else
  fail "IS6: destination was created on dry run"
fi

# -----------------------------------------------------------------------------
# IS7: 대상 디렉터리가 존재하지 않는 초기 상태 → mkdir -p 로 생성
# -----------------------------------------------------------------------------
echo "== IS7: destination auto-created =="

DEST7="${TMPROOT}/nested/deeper/dest7"
out7=$(run_install "${DEST7}")
rc7=$?
assert_eq "0" "${rc7}" "IS7: run with nonexistent dest exits 0"

if [[ -d "${DEST7}" ]]; then
  pass "IS7: destination directory created"
else
  fail "IS7: destination directory not created"
fi

if [[ -L "${DEST7}/wiki-ingest-all" ]]; then
  pass "IS7: symlink created in new directory"
else
  fail "IS7: symlink not created in new directory"
fi

# -----------------------------------------------------------------------------
echo
echo "install-skills tests: PASS=${PASS} FAIL=${FAIL}"
if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
