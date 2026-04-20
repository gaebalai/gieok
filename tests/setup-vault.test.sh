#!/usr/bin/env bash
#
# setup-vault.test.sh — scripts/setup-vault.sh의 스모크 테스트
#
# 실행: bash tools/claude-brain/tests/setup-vault.test.sh
#
# 방침:
#   - 실 Vault는 절대 건드리지 않음. 모든 테스트는 mktemp -d의 tmpdir 내에서 완결
#   - 네트워크 접근 없음
#   - trap으로 tmpdir을 확실히 클린업
#   - bats에 의존하지 않고 자작 간이 어서션 함수를 사용

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SETUP_VAULT="${REPO_ROOT}/tools/claude-brain/scripts/setup-vault.sh"

if [[ ! -x "${SETUP_VAULT}" && ! -f "${SETUP_VAULT}" ]]; then
  echo "FATAL: setup-vault.sh not found at ${SETUP_VAULT}" >&2
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

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${msg}"
  else
    fail "${msg} (expected=${expected}, actual=${actual})"
  fi
}

assert_file_exists() {
  local path="$1"
  local msg="$2"
  if [[ -f "${path}" ]]; then
    pass "${msg}"
  else
    fail "${msg} (file missing: ${path})"
  fi
}

assert_dir_exists() {
  local path="$1"
  local msg="$2"
  if [[ -d "${path}" ]]; then
    pass "${msg}"
  else
    fail "${msg} (dir missing: ${path})"
  fi
}

# -----------------------------------------------------------------------------
# Test 1: OBSIDIAN_VAULT 미설정이면 exit 1
# -----------------------------------------------------------------------------
echo "test: unset OBSIDIAN_VAULT -> exit 1"
set +e
(
  unset OBSIDIAN_VAULT
  bash "${SETUP_VAULT}" >/dev/null 2>&1
)
rc=$?
set -e
assert_eq "1" "${rc}" "exit code 1 when OBSIDIAN_VAULT unset"

# -----------------------------------------------------------------------------
# Test 2: 존재하지 않는 경로면 exit 2
# -----------------------------------------------------------------------------
echo "test: nonexistent path -> exit 2"
set +e
OBSIDIAN_VAULT="${TMPROOT}/does-not-exist" bash "${SETUP_VAULT}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "2" "${rc}" "exit code 2 when path does not exist"

# -----------------------------------------------------------------------------
# Test 3: 경로가 파일이면 exit 2
# -----------------------------------------------------------------------------
echo "test: path is a file -> exit 2"
touch "${TMPROOT}/not-a-dir"
set +e
OBSIDIAN_VAULT="${TMPROOT}/not-a-dir" bash "${SETUP_VAULT}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "2" "${rc}" "exit code 2 when path is a file"

# -----------------------------------------------------------------------------
# Test 4: 빈 Vault에의 초기화
# -----------------------------------------------------------------------------
echo "test: fresh vault initialization"
VAULT="${TMPROOT}/vault-fresh"
mkdir -p "${VAULT}"
OBSIDIAN_VAULT="${VAULT}" bash "${SETUP_VAULT}" >/dev/null
assert_dir_exists "${VAULT}/raw-sources/articles" "raw-sources/articles created"
assert_dir_exists "${VAULT}/raw-sources/papers" "raw-sources/papers created"
assert_dir_exists "${VAULT}/raw-sources/books" "raw-sources/books created"
assert_dir_exists "${VAULT}/raw-sources/ideas" "raw-sources/ideas created"
assert_dir_exists "${VAULT}/raw-sources/transcripts" "raw-sources/transcripts created"
assert_dir_exists "${VAULT}/session-logs" "session-logs created"
assert_dir_exists "${VAULT}/wiki/concepts" "wiki/concepts created"
assert_dir_exists "${VAULT}/wiki/projects" "wiki/projects created"
assert_dir_exists "${VAULT}/wiki/decisions" "wiki/decisions created"
assert_dir_exists "${VAULT}/wiki/patterns" "wiki/patterns created"
assert_dir_exists "${VAULT}/wiki/bugs" "wiki/bugs created"
assert_dir_exists "${VAULT}/wiki/people" "wiki/people created"
assert_dir_exists "${VAULT}/wiki/summaries" "wiki/summaries created"
assert_dir_exists "${VAULT}/wiki/analyses" "wiki/analyses created"
assert_dir_exists "${VAULT}/templates" "templates dir created"
assert_file_exists "${VAULT}/CLAUDE.md" "CLAUDE.md placed"
assert_file_exists "${VAULT}/.gitignore" ".gitignore placed"
assert_file_exists "${VAULT}/wiki/index.md" "wiki/index.md placed"
assert_file_exists "${VAULT}/wiki/log.md" "wiki/log.md placed"
assert_file_exists "${VAULT}/templates/concept.md" "templates/concept.md placed"
assert_file_exists "${VAULT}/templates/project.md" "templates/project.md placed"
assert_file_exists "${VAULT}/templates/decision.md" "templates/decision.md placed"
assert_file_exists "${VAULT}/templates/source-summary.md" "templates/source-summary.md placed"

# .cache/는 setup-vault.sh에서는 만들지 않음 (auto-ingest.sh가 실행 시 생성).
# 대신 .gitignore에 .cache/ 엔트리가 포함되어 있는지 검증한다.
if grep -q '^\.cache/' "${VAULT}/.gitignore"; then
  pass ".gitignore excludes .cache/"
else
  fail ".gitignore should exclude .cache/ (PDF 추출 캐시)"
fi

# 기능 2.1: cron auto-ingest와 MCP가 공유하는 lockfile을 git에 포함하지 않음
if grep -q '^\.gieok-mcp\.lock$' "${VAULT}/.gitignore"; then
  pass ".gitignore excludes .gieok-mcp.lock (feature 2.1)"
else
  fail ".gitignore should exclude .gieok-mcp.lock (cron/MCP shared lockfile)"
fi

# 기능 2.2: URL pre-step이 취득한 raw HTML cache (debug / 재추출용)를 git에 포함하지 않음
if grep -q '^\.cache/html/' "${VAULT}/.gitignore"; then
  pass ".gitignore excludes .cache/html/ (feature 2.2)"
else
  fail ".gitignore should exclude .cache/html/ (URL raw HTML cache)"
fi

# 기능 2.2 / v0.3.1 HIGH-c1 fix: fetched/의 이미지 로컬 저장 영역을 git에서 제외
# (공격용 HTML이 심어둔 대량 이미지로 Vault repo가 팽창하는 것을 방어)
if grep -q '^raw-sources/\*\*/fetched/media/' "${VAULT}/.gitignore"; then
  pass ".gitignore excludes raw-sources/**/fetched/media/ (HIGH-c1)"
else
  fail ".gitignore should exclude raw-sources/**/fetched/media/ (attacker image DoS)"
fi

# -----------------------------------------------------------------------------
# Test 5: 멱등성 — 2회째 실행에서 기존 파일을 손상시키지 않음
# -----------------------------------------------------------------------------
echo "test: idempotency"
# 사용자 편집을 모방
echo "user-edited content" > "${VAULT}/wiki/index.md"
user_claude_hash_before="$(shasum "${VAULT}/CLAUDE.md" | awk '{print $1}')"
user_index_hash_before="$(shasum "${VAULT}/wiki/index.md" | awk '{print $1}')"

OBSIDIAN_VAULT="${VAULT}" bash "${SETUP_VAULT}" >/dev/null

user_claude_hash_after="$(shasum "${VAULT}/CLAUDE.md" | awk '{print $1}')"
user_index_hash_after="$(shasum "${VAULT}/wiki/index.md" | awk '{print $1}')"

assert_eq "${user_claude_hash_before}" "${user_claude_hash_after}" "CLAUDE.md unchanged on re-run"
assert_eq "${user_index_hash_before}" "${user_index_hash_after}" "user-edited wiki/index.md preserved"

# -----------------------------------------------------------------------------
# Test 6: 기존 CLAUDE.md가 있으면 CLAUDE.brain.md로 대피
# -----------------------------------------------------------------------------
echo "test: existing CLAUDE.md -> CLAUDE.brain.md"
VAULT2="${TMPROOT}/vault-with-claude"
mkdir -p "${VAULT2}"
echo "my personal CLAUDE" > "${VAULT2}/CLAUDE.md"
original_hash="$(shasum "${VAULT2}/CLAUDE.md" | awk '{print $1}')"

OBSIDIAN_VAULT="${VAULT2}" bash "${SETUP_VAULT}" >/dev/null

after_hash="$(shasum "${VAULT2}/CLAUDE.md" | awk '{print $1}')"
assert_eq "${original_hash}" "${after_hash}" "existing CLAUDE.md not overwritten"
assert_file_exists "${VAULT2}/CLAUDE.brain.md" "CLAUDE.brain.md created as alternative"

# -----------------------------------------------------------------------------
# Test 7: dry-run에서는 파일을 만들지 않음
# -----------------------------------------------------------------------------
echo "test: dry-run does not write"
VAULT3="${TMPROOT}/vault-dry"
mkdir -p "${VAULT3}"
GIEOK_DRY_RUN=1 OBSIDIAN_VAULT="${VAULT3}" bash "${SETUP_VAULT}" >/dev/null
file_count=$(find "${VAULT3}" -mindepth 1 | wc -l | tr -d ' ')
assert_eq "0" "${file_count}" "dry-run left vault untouched"

# -----------------------------------------------------------------------------
# Test 8: 기존 .gitignore는 덮어쓰지 않음
# -----------------------------------------------------------------------------
echo "test: existing .gitignore preserved"
VAULT4="${TMPROOT}/vault-with-gitignore"
mkdir -p "${VAULT4}"
echo "node_modules/" > "${VAULT4}/.gitignore"
original_gi_hash="$(shasum "${VAULT4}/.gitignore" | awk '{print $1}')"

OBSIDIAN_VAULT="${VAULT4}" bash "${SETUP_VAULT}" >/dev/null

after_gi_hash="$(shasum "${VAULT4}/.gitignore" | awk '{print $1}')"
assert_eq "${original_gi_hash}" "${after_gi_hash}" "existing .gitignore preserved"

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
