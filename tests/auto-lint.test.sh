#!/usr/bin/env bash
#
# auto-lint.test.sh — scripts/auto-lint.sh 스모크 테스트
#
# 실행: bash tools/claude-brain/tests/auto-lint.test.sh
#
# 검증 항목 (Phase G.5 / G1~G5):
#   G1 wiki 페이지 0건 → claude 호출 없이 exit 0
#   G2 OBSIDIAN_VAULT 가 존재하지 않음 → exit 1
#   G3 claude 명령이 PATH 에 없음 → exit 1
#   G4 wiki 페이지 있음 + DRY RUN → lint-report.md 가 생성됨
#   G5 비 git vault → Lint 처리 자체는 성공 (git 은 silently skip)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
AUTO_LINT="${REPO_ROOT}/tools/claude-brain/scripts/auto-lint.sh"

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

# -----------------------------------------------------------------------------
# stub claude 바이너리
# -----------------------------------------------------------------------------
STUB_DIR="${TMPROOT}/stub-bin"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/claude" <<'STUB'
#!/usr/bin/env bash
echo "stub-claude called with $# args" >&2
exit 0
STUB
chmod +x "${STUB_DIR}/claude"

# -----------------------------------------------------------------------------
# 유효한 vault 를 만드는 헬퍼
# -----------------------------------------------------------------------------
make_vault() {
  local name="$1"
  local vault="${TMPROOT}/${name}"
  mkdir -p "${vault}/session-logs" "${vault}/wiki" "${vault}/raw-sources" "${vault}/templates"
  : > "${vault}/CLAUDE.md"
  echo "${vault}"
}

add_wiki_page() {
  local vault="$1"
  local name="$2"
  cat > "${vault}/wiki/${name}.md" <<EOF
---
title: ${name}
tags: [test]
updated: 2026-04-15
---

# ${name}

body
EOF
}

# -----------------------------------------------------------------------------
# Test G2: OBSIDIAN_VAULT 가 존재하지 않음 → exit 1
# -----------------------------------------------------------------------------
echo "test G2: missing OBSIDIAN_VAULT -> exit 1"
set +e
(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${TMPROOT}/does-not-exist" \
  bash "${AUTO_LINT}" >/dev/null 2>&1
)
rc=$?
set -e
assert_eq "1" "${rc}" "G2 exit code 1 when vault missing"

# -----------------------------------------------------------------------------
# Test G3: claude 명령이 PATH 에 없음 → exit 1
# -----------------------------------------------------------------------------
echo "test G3: claude not in PATH -> exit 1"
VAULT_G3="$(make_vault vault-g3)"
FAKE_HOME_G3="${TMPROOT}/fake-home-g3"
mkdir -p "${FAKE_HOME_G3}"
set +e
out_g3="$(
  env -i \
    HOME="${FAKE_HOME_G3}" \
    PATH="/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_G3}" \
    bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "1" "${rc}" "G3 exit code 1 when claude missing"
assert_contains "${out_g3}" "claude command not found" "G3 error message present"

# -----------------------------------------------------------------------------
# Test G1: wiki 페이지 0건 → claude 호출 없이 exit 0
# -----------------------------------------------------------------------------
echo "test G1: no wiki pages -> skip"
VAULT_G1="$(make_vault vault-g1)"
# index.md / log.md / lint-report.md 는 카운트 대상 외이므로 배치해도 0으로 취급됨
: > "${VAULT_G1}/wiki/index.md"
: > "${VAULT_G1}/wiki/log.md"
set +e
out_g1="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_G1}" \
  bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "G1 exit code 0 when wiki empty"
assert_contains "${out_g1}" "no content pages" "G1 skip message present"
if printf '%s' "${out_g1}" | grep -q "stub-claude called"; then
  fail "G1 claude stub should NOT be called"
else
  pass "G1 claude stub was not called"
fi

# -----------------------------------------------------------------------------
# Test G4: wiki 페이지 있음 + DRY RUN → lint-report.md 가 생성됨
# -----------------------------------------------------------------------------
echo "test G4: wiki pages present + dry run -> lint-report.md generated"
VAULT_G4="$(make_vault vault-g4)"
add_wiki_page "${VAULT_G4}" "concept-a"
add_wiki_page "${VAULT_G4}" "concept-b"
(cd "${VAULT_G4}" && git init --quiet && git -c user.email=t@test -c user.name=t commit --allow-empty -m init --quiet)

set +e
out_g4="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_G4}" \
  GIEOK_DRY_RUN=1 \
  bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "G4 exit code 0"
assert_contains "${out_g4}" "Found 2 wiki page" "G4 counted 2 pages"
assert_contains "${out_g4}" "DRY RUN: would call claude" "G4 reached lint call (dry run)"
if [[ -f "${VAULT_G4}/wiki/lint-report.md" ]]; then
  pass "G4 lint-report.md exists"
else
  fail "G4 lint-report.md was not created"
fi

# -----------------------------------------------------------------------------
# Test G5: 비 git vault → Lint 는 성공, git 작업은 silent skip
# -----------------------------------------------------------------------------
echo "test G5: non-git vault -> lint succeeds, git skipped"
VAULT_G5="$(make_vault vault-g5)"
add_wiki_page "${VAULT_G5}" "concept-c"

set +e
out_g5="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_G5}" \
  GIEOK_DRY_RUN=1 \
  bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "G5 exit code 0 for non-git vault"
assert_contains "${out_g5}" "DRY RUN: would call claude" "G5 lint path reached"
assert_contains "${out_g5}" "DRY RUN: skipping git" "G5 dry-run git skip notice present"

# -----------------------------------------------------------------------------
# Test G6: 자가 진단 섹션의 max_turns 감지 (#4)
# 가짜 ingest 로그에 "max turns" 를 심어, WARNING 이 나오는지 확인
# -----------------------------------------------------------------------------
echo "test G6: self-diagnostics detects max_turns in ingest log"
VAULT_G6="$(make_vault vault-g6)"
add_wiki_page "${VAULT_G6}" "concept-d"
FAKE_INGEST_LOG="${TMPROOT}/fake-ingest-g6.log"
cat > "${FAKE_INGEST_LOG}" <<'LOG'
[auto-ingest 20260101-0700] Processing 2 logs...
Error: reached max turns without completing the task.
LOG

set +e
out_g6="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_G6}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_INGEST_LOG="${FAKE_INGEST_LOG}" \
  bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "G6 exit code 0"
assert_contains "${out_g6}" "self-diagnostics" "G6 diagnostics header present"
assert_contains "${out_g6}" "[#4] WARNING" "G6 max_turns warning present"

# -----------------------------------------------------------------------------
# Test G7: 자가 진단 섹션의 OK 경로 (#4 정상 / #5 스킵 or 본문 / #6 OK)
# ingest 로그에 max_turns 가 없으면 OK 메시지
# -----------------------------------------------------------------------------
echo "test G7: self-diagnostics OK path"
VAULT_G7="$(make_vault vault-g7)"
add_wiki_page "${VAULT_G7}" "concept-e"
FAKE_INGEST_LOG_CLEAN="${TMPROOT}/fake-ingest-g7.log"
printf '[auto-ingest 20260101-0700] OK: processed 3 logs.\n' > "${FAKE_INGEST_LOG_CLEAN}"

set +e
out_g7="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_G7}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_INGEST_LOG="${FAKE_INGEST_LOG_CLEAN}" \
  bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "G7 exit code 0"
assert_contains "${out_g7}" "[#4] OK" "G7 max_turns OK"
assert_contains "${out_g7}" "[#6] OK" "G7 scan-secrets OK"

# -----------------------------------------------------------------------------
# Test G8: 자가 진단의 #6 이 session-logs/ 에서 누출을 감지할 수 있음
# -----------------------------------------------------------------------------
echo "test G8: self-diagnostics detects secret leak via scan-secrets"
VAULT_G8="$(make_vault vault-g8)"
add_wiki_page "${VAULT_G8}" "concept-f"
cat > "${VAULT_G8}/session-logs/20260101-090000-test-leak.md" <<'LEAK'
---
type: session-log
---
oops: ghp_abcdefghijklmnopqrstuvwxyz0123456789
LEAK

set +e
out_g8="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_G8}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_INGEST_LOG="${TMPROOT}/nonexistent-g8.log" \
  bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "G8 exit code 0 (auto-lint itself still succeeds)"
assert_contains "${out_g8}" "[#6] WARNING" "G8 scan-secrets warning present"
assert_contains "${out_g8}" "GitHub personal access token" "G8 leak category reported"

# -----------------------------------------------------------------------------
# 기능 2.1 (R1: Unicode 비가시 문자 감지) — LINT_PROMPT 로의 주입을 검증
# -----------------------------------------------------------------------------
# 방침: auto-ingest 의 I1-I3 과 동일하게 stub claude 로 -p 인자를 캡처하여
# LINT_PROMPT 의 문자열을 검사한다. DRY RUN 에서는 프롬프트 본문을 출력하지 않으므로
# 실제 경로 (stub claude) 로 테스트한다.
# -----------------------------------------------------------------------------

CAPTURE_DIR_LINT="${TMPROOT}/capture-lint"
mkdir -p "${CAPTURE_DIR_LINT}"
CAPTURE_FILE_LINT="${CAPTURE_DIR_LINT}/last-prompt.txt"

STUB_CAPTURE_DIR_LINT="${TMPROOT}/stub-capture-bin-lint"
mkdir -p "${STUB_CAPTURE_DIR_LINT}"
cat > "${STUB_CAPTURE_DIR_LINT}/claude" <<STUB
#!/usr/bin/env bash
# Test stub for auto-lint: capture the -p prompt body to a file.
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -p)
      shift
      printf '%s' "\$1" > "${CAPTURE_FILE_LINT}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
exit 0
STUB
chmod +x "${STUB_CAPTURE_DIR_LINT}/claude"

# ---------------------------------------------------------------------------
# Test R1-1: wiki 에 ZWSP 를 포함한 페이지가 있으면 LINT_PROMPT 에 findings 가 주입됨
# ---------------------------------------------------------------------------
echo "test R1-1: ZWSP in wiki page is reported in LINT_PROMPT"
VAULT_R1A="$(make_vault vault-r1a)"
# ZWSP (U+200B) 를 포함한 wiki 페이지를 만든다
printf -- '---\ntitle: zwsp-page\nupdated: 2026-04-17\n---\n\nhello\xe2\x80\x8bworld\n' \
  > "${VAULT_R1A}/wiki/zwsp-page.md"
FAKE_HOME_R1A="${TMPROOT}/fake-home-r1a"
mkdir -p "${FAKE_HOME_R1A}"

rm -f "${CAPTURE_FILE_LINT}"
set +e
out_r1a="$(
  env -i \
    HOME="${FAKE_HOME_R1A}" \
    PATH="${STUB_CAPTURE_DIR_LINT}:/usr/bin:/bin:$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/false)")" \
    OBSIDIAN_VAULT="${VAULT_R1A}" \
    bash "${AUTO_LINT}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "R1-1 exit code 0"
if [[ ! -f "${CAPTURE_FILE_LINT}" ]]; then
  fail "R1-1 prompt capture created"
else
  pass "R1-1 prompt capture created"
  captured_r1a="$(cat "${CAPTURE_FILE_LINT}")"
  assert_contains "${captured_r1a}" "R1 pre-scan findings" "R1-1 prompt contains R1 pre-scan section"
  assert_contains "${captured_r1a}" "wiki/zwsp-page.md" "R1-1 findings include the offending page"
  assert_contains "${captured_r1a}" "lines 6" "R1-1 findings include the line number"
fi

# ---------------------------------------------------------------------------
# Test R1-2: RTLO 를 포함한 페이지가 감지됨
# ---------------------------------------------------------------------------
echo "test R1-2: RTLO (U+202E) is also detected"
VAULT_R1B="$(make_vault vault-r1b)"
# RTLO U+202E = 0xE2 0x80 0xAE
printf -- '---\ntitle: rtlo-page\n---\n\nnormal\xe2\x80\xaereversed\n' \
  > "${VAULT_R1B}/wiki/rtlo-page.md"
FAKE_HOME_R1B="${TMPROOT}/fake-home-r1b"
mkdir -p "${FAKE_HOME_R1B}"

rm -f "${CAPTURE_FILE_LINT}"
set +e
env -i \
  HOME="${FAKE_HOME_R1B}" \
  PATH="${STUB_CAPTURE_DIR_LINT}:/usr/bin:/bin:$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/false)")" \
  OBSIDIAN_VAULT="${VAULT_R1B}" \
  bash "${AUTO_LINT}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "0" "${rc}" "R1-2 exit code 0"
if [[ -f "${CAPTURE_FILE_LINT}" ]]; then
  captured_r1b="$(cat "${CAPTURE_FILE_LINT}")"
  assert_contains "${captured_r1b}" "wiki/rtlo-page.md" "R1-2 RTLO page flagged"
fi

# ---------------------------------------------------------------------------
# Test R1-2b (security review LOW-1): 파일명에 백틱이 포함되어 있어도
#            LINT_PROMPT 의 findings 섹션이 파괴되지 않음 (self-injection 대책)
# ---------------------------------------------------------------------------
echo "test R1-2b: backtick in filename is sanitized (self-injection defense)"
VAULT_R1D="$(make_vault vault-r1d)"
# Filename contains a backtick (rare but legal on macOS/Linux). Content has ZWSP.
# Writing via printf so the literal backtick ends up in the filename.
EVIL_NAME=$'evil`page.md'
printf -- '---\ntitle: evil\n---\n\nhi\xe2\x80\x8bthere\n' \
  > "${VAULT_R1D}/wiki/${EVIL_NAME}"
FAKE_HOME_R1D="${TMPROOT}/fake-home-r1d"
mkdir -p "${FAKE_HOME_R1D}"

rm -f "${CAPTURE_FILE_LINT}"
set +e
env -i \
  HOME="${FAKE_HOME_R1D}" \
  PATH="${STUB_CAPTURE_DIR_LINT}:/usr/bin:/bin:$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/false)")" \
  OBSIDIAN_VAULT="${VAULT_R1D}" \
  bash "${AUTO_LINT}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "0" "${rc}" "R1-2b exit code 0"
if [[ -f "${CAPTURE_FILE_LINT}" ]]; then
  captured_r1d="$(cat "${CAPTURE_FILE_LINT}")"
  # findings 행에 생 backtick 이 포함되지 않았을 것 (sanitize 로 ? 로 치환됨)
  # → codefence ` wiki/evil`page.md ` 를 탈출할 수 없다
  if printf '%s' "${captured_r1d}" | grep -Fq 'wiki/evil`page.md'; then
    fail "R1-2b raw backtick in filename leaked to prompt"
  else
    pass "R1-2b backtick sanitized (not leaked as raw \`)"
  fi
  assert_contains "${captured_r1d}" "wiki/evil?page.md" "R1-2b sanitized filename present with ? replacement"
fi

# ---------------------------------------------------------------------------
# Test R1-3: 비가시 문자 없음 → LINT_PROMPT 에 "해당 없음" 이라고 기록됨
# ---------------------------------------------------------------------------
echo "test R1-3: no invisible chars -> prompt mentions '해당 없음'"
VAULT_R1C="$(make_vault vault-r1c)"
add_wiki_page "${VAULT_R1C}" "clean-page"
FAKE_HOME_R1C="${TMPROOT}/fake-home-r1c"
mkdir -p "${FAKE_HOME_R1C}"

rm -f "${CAPTURE_FILE_LINT}"
set +e
env -i \
  HOME="${FAKE_HOME_R1C}" \
  PATH="${STUB_CAPTURE_DIR_LINT}:/usr/bin:/bin:$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/false)")" \
  OBSIDIAN_VAULT="${VAULT_R1C}" \
  bash "${AUTO_LINT}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "0" "${rc}" "R1-3 exit code 0"
if [[ -f "${CAPTURE_FILE_LINT}" ]]; then
  captured_r1c="$(cat "${CAPTURE_FILE_LINT}")"
  assert_contains "${captured_r1c}" "R1 pre-scan findings" "R1-3 prompt still has R1 section header"
  assert_contains "${captured_r1c}" "해당 없음" "R1-3 prompt records '해당 없음' when no findings"
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
