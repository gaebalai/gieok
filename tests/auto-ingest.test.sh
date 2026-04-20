#!/usr/bin/env bash
#
# auto-ingest.test.sh — scripts/auto-ingest.sh 스모크 테스트
#
# 실행: bash tools/claude-brain/tests/auto-ingest.test.sh
#
# 검증 항목 (Phase F.6 / F1~F5):
#   F1 미처리 로그 0건 → claude 호출 없이 exit 0
#   F2 OBSIDIAN_VAULT 가 존재하지 않음 → exit 1
#   F3 claude 명령이 PATH 에 없음 → exit 1
#   F4 미처리 로그 있음 + DRY RUN → claude 를 호출하는 경로에 도달함
#   F5 비 git vault → Ingest 처리 자체는 성공 (git 은 silently fail)
#
# Phase I (wiki/analyses/ 추출) 추가 케이스:
#   I1 INGEST_PROMPT 에 wiki/analyses/ 로의 저장 지시가 포함됨
#   I2 INGEST_PROMPT 에 kebab-case 파일명 지시와 범용 지식 우선 지시가 포함됨
#   I3 INGEST_PROMPT 에 "동일명 페이지는 업데이트 (중복 금지)" 지시가 포함됨

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
AUTO_INGEST="${REPO_ROOT}/tools/claude-brain/scripts/auto-ingest.sh"

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
# stub claude 바이너리 (F1, F4, F5 에서 사용)
# -----------------------------------------------------------------------------
STUB_DIR="${TMPROOT}/stub-bin"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/claude" <<'STUB'
#!/usr/bin/env bash
# Test stub: record invocation args, never call real API
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

add_unprocessed_log() {
  local vault="$1"
  local name="$2"
  cat > "${vault}/session-logs/${name}.md" <<EOF
---
type: session-log
session_id: ${name}
ingested: false
---

body
EOF
}

# -----------------------------------------------------------------------------
# Test F2: OBSIDIAN_VAULT 가 존재하지 않음 → exit 1
# -----------------------------------------------------------------------------
echo "test F2: missing OBSIDIAN_VAULT -> exit 1"
set +e
(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${TMPROOT}/does-not-exist" \
  bash "${AUTO_INGEST}" >/dev/null 2>&1
)
rc=$?
set -e
assert_eq "1" "${rc}" "F2 exit code 1 when vault missing"

# -----------------------------------------------------------------------------
# Test F3: claude 명령이 PATH 에 없음 → exit 1
# -----------------------------------------------------------------------------
# fake HOME 을 가리킴으로써, 스크립트 내 PATH 보완 ($HOME/.local/bin 등) 도
# 존재하지 않는 디렉터리가 된다. 이 머신의 /usr/local/bin, /opt/homebrew/bin
# 에는 claude 가 설치되어 있지 않다는 것을 전제로 한다 (사전 확인 완료).
echo "test F3: claude not in PATH -> exit 1"
VAULT_F3="$(make_vault vault-f3)"
FAKE_HOME_F3="${TMPROOT}/fake-home-f3"
mkdir -p "${FAKE_HOME_F3}"
set +e
out_f3="$(
  env -i \
    HOME="${FAKE_HOME_F3}" \
    PATH="/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_F3}" \
    bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "1" "${rc}" "F3 exit code 1 when claude missing"
assert_contains "${out_f3}" "claude command not found" "F3 error message present"

# -----------------------------------------------------------------------------
# Test F1: 미처리 로그 0건 → claude 호출 없이 exit 0
# -----------------------------------------------------------------------------
echo "test F1: no unprocessed logs -> skip"
VAULT_F1="$(make_vault vault-f1)"
# 이미 취합 완료된 로그 (ingested: true) 만 배치
cat > "${VAULT_F1}/session-logs/already-done.md" <<'EOF'
---
type: session-log
ingested: true
---
EOF
set +e
out_f1="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F1}" \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F1 exit code 0 when nothing to ingest"
assert_contains "${out_f1}" "No unprocessed logs" "F1 skip message present"
# stub claude 가 호출되지 않았음을 확인
if printf '%s' "${out_f1}" | grep -q "stub-claude called"; then
  fail "F1 claude stub should NOT be called"
else
  pass "F1 claude stub was not called"
fi

# -----------------------------------------------------------------------------
# Test F4: 미처리 로그 있음 + DRY RUN → claude 호출 경로에 도달
# -----------------------------------------------------------------------------
echo "test F4: unprocessed logs present + dry run -> reaches ingest call"
VAULT_F4="$(make_vault vault-f4)"
add_unprocessed_log "${VAULT_F4}" "20260415-100000-test-a"
add_unprocessed_log "${VAULT_F4}" "20260415-100100-test-b"
# git init 해두면 git pull/push 가 silently fail 하지만 처리는 완주한다
(cd "${VAULT_F4}" && git init --quiet && git -c user.email=t@test -c user.name=t commit --allow-empty -m init --quiet)

set +e
out_f4="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F4}" \
  GIEOK_DRY_RUN=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F4 exit code 0"
assert_contains "${out_f4}" "Found 2 unprocessed log" "F4 counted 2 logs"
assert_contains "${out_f4}" "DRY RUN: would call claude" "F4 reached ingest call (dry run)"
assert_contains "${out_f4}" "Done." "F4 completed"

# -----------------------------------------------------------------------------
# Test F5: 비 git vault → Ingest 는 성공, git 작업은 silent fail
# -----------------------------------------------------------------------------
echo "test F5: non-git vault -> ingest succeeds, git silently fails"
VAULT_F5="$(make_vault vault-f5)"
add_unprocessed_log "${VAULT_F5}" "20260415-110000-test-c"

set +e
out_f5="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F5}" \
  GIEOK_DRY_RUN=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F5 exit code 0 for non-git vault"
assert_contains "${out_f5}" "DRY RUN: would call claude" "F5 ingest path reached"
# git 명령의 에러 출력은 2>/dev/null 로 눌려 있으므로 육안으로 확인하지 않아도 된다

# -----------------------------------------------------------------------------
# Phase I: wiki/analyses/ 추출 지시가 INGEST_PROMPT 에 포함되는지 검증
#
# 방침:
#   claude 를 stub 으로 만들어 argv[2] (프롬프트 본문) 을 임시 파일에 기록한다.
#   그 파일을 grep 해서 프롬프트 내용을 검사한다.
#   DRY RUN 에서는 프롬프트 본문을 stdout 에 내보내지 않는 설계이므로 이 방식을 채택한다.
# -----------------------------------------------------------------------------
echo "test I1-I3: INGEST_PROMPT contains wiki/analyses/ extraction instructions"

CAPTURE_DIR="${TMPROOT}/capture"
mkdir -p "${CAPTURE_DIR}"
CAPTURE_FILE="${CAPTURE_DIR}/last-prompt.txt"

STUB_CAPTURE_DIR="${TMPROOT}/stub-capture-bin"
mkdir -p "${STUB_CAPTURE_DIR}"
cat > "${STUB_CAPTURE_DIR}/claude" <<STUB
#!/usr/bin/env bash
# Test stub: capture the -p prompt body to a file for inspection.
# argv is: -p <PROMPT> --allowedTools ... --max-turns ...
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -p)
      shift
      printf '%s' "\$1" > "${CAPTURE_FILE}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
exit 0
STUB
chmod +x "${STUB_CAPTURE_DIR}/claude"

VAULT_I="$(make_vault vault-i)"
add_unprocessed_log "${VAULT_I}" "20260415-120000-test-i"
(cd "${VAULT_I}" && git init --quiet && git -c user.email=t@test -c user.name=t commit --allow-empty -m init --quiet)

# auto-ingest.sh 는 PATH 의 선두에 $HOME/.volta/bin 을 추가하기 때문에,
# 그대로 PATH=stub:... 로 하면 실제 머신의 claude 로 덮어쓰일 가능성이 있다.
# fake HOME 을 사용해 Volta 등의 실제 경로를 존재하지 않는 디렉터리로 보내고,
# stub 만 보이는 상태를 만든다.
FAKE_HOME_I="${TMPROOT}/fake-home-i"
mkdir -p "${FAKE_HOME_I}"

set +e
out_i="$(
  env -i \
    HOME="${FAKE_HOME_I}" \
    PATH="${STUB_CAPTURE_DIR}:/usr/bin:/bin" \
    OBSIDIAN_VAULT="${VAULT_I}" \
    bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "I exit code 0"

if [[ ! -f "${CAPTURE_FILE}" ]]; then
  fail "I prompt capture file was created"
else
  pass "I prompt capture file was created"
  captured="$(cat "${CAPTURE_FILE}")"

  # I1: wiki/analyses/ 로의 저장 지시
  assert_contains "${captured}" "wiki/analyses/" "I1 prompt mentions wiki/analyses/"
  assert_contains "${captured}" "페이지로 저장" "I1 prompt instructs to save as a page"

  # I2: kebab-case 파일명 + 범용 지식 우선
  assert_contains "${captured}" "kebab-case" "I2 prompt specifies kebab-case filename"
  assert_contains "${captured}" "범용적" "I2 prompt prefers generic knowledge"

  # I3: 동일명 페이지는 업데이트 (중복 금지)
  assert_contains "${captured}" "기존 페이지를 갱신" "I3 prompt instructs to update existing page"
  assert_contains "${captured}" "중복" "I3 prompt forbids duplicates"
fi

# -----------------------------------------------------------------------------
# Feature 2 (PDF ingest) 관련 — F6 / F7 / F8
# -----------------------------------------------------------------------------

# auto-ingest.sh 의 PDF pre-step 은 pdfinfo + pdftotext 가 PATH 에 없으면
# 통째로 스킵된다. 여기만 스킵하면 테스트의 의미가 약해지므로,
# poppler 미설치 환경에서는 F6/F7/F8 를 skip 한다.
if ! command -v pdfinfo >/dev/null 2>&1 || ! command -v pdftotext >/dev/null 2>&1; then
  echo ""
  echo "SKIP F6/F7/F8: poppler (pdfinfo/pdftotext) not installed" >&2
else
  # ---------------------------------------------------------------------------
  # Test F6: raw-sources/<subdir>/<name>.pdf 배치 시에 extract-pdf.sh 가
  #          올바른 3개 인자로 호출된다 (stub 으로 argv 를 기록하여 검증)
  # ---------------------------------------------------------------------------
  echo "test F6: PDF pre-step invokes extract-pdf.sh with correct args"
  VAULT_F6="$(make_vault vault-f6)"
  # raw-sources/papers/ 를 만들고 더미 PDF (크기 0 이어도 OK, stub 이 처리하기 때문) 를 배치
  mkdir -p "${VAULT_F6}/raw-sources/papers"
  : > "${VAULT_F6}/raw-sources/papers/attention.pdf"
  # 세션 로그도 1건 배치해 claude 호출까지 도달시킨다
  add_unprocessed_log "${VAULT_F6}" "20260417-100000-f6"

  STUB_EXTRACT_F6="${TMPROOT}/stub-extract-f6.sh"
  ARGS_FILE_F6="${TMPROOT}/extract-f6.args"
  cat > "${STUB_EXTRACT_F6}" <<STUB
#!/usr/bin/env bash
# stub: record argv to a file and exit 0
printf 'argv: %s\n' "\$*" > "${ARGS_FILE_F6}"
exit 0
STUB
  chmod +x "${STUB_EXTRACT_F6}"

  set +e
  out_f6="$(
    PATH="${STUB_DIR}:${PATH}" \
    OBSIDIAN_VAULT="${VAULT_F6}" \
    GIEOK_DRY_RUN=1 \
    GIEOK_EXTRACT_PDF_SCRIPT="${STUB_EXTRACT_F6}" \
    GIEOK_ALLOW_EXTRACT_PDF_OVERRIDE=1 \
    bash "${AUTO_INGEST}" 2>&1
  )"
  rc=$?
  set -e
  assert_eq "0" "${rc}" "F6 exit code 0"
  assert_file_exists() {
    if [[ -f "$1" ]]; then pass "$2"; else fail "$2 (file missing: $1)"; fi
  }
  assert_file_exists "${ARGS_FILE_F6}" "F6 stub extract-pdf.sh was invoked"
  if [[ -f "${ARGS_FILE_F6}" ]]; then
    args_f6="$(cat "${ARGS_FILE_F6}")"
    assert_contains "${args_f6}" "raw-sources/papers/attention.pdf" "F6 argv contains PDF path"
    assert_contains "${args_f6}" ".cache/extracted" "F6 argv contains cache dir"
    assert_contains "${args_f6}" "papers" "F6 argv contains subdir prefix"
  fi

  # ---------------------------------------------------------------------------
  # Test F7: .cache/extracted/*.md 에서 대응 summary 부재 → 미처리 카운트에 포함됨
  # ---------------------------------------------------------------------------
  echo "test F7: .cache/extracted/ MD without summary increases UNPROCESSED_SOURCES"
  VAULT_F7="$(make_vault vault-f7)"
  mkdir -p "${VAULT_F7}/.cache/extracted" "${VAULT_F7}/wiki/summaries"
  # stem = papers-attention-pp001-008 (extract-pdf.sh 의 명명 규칙)
  cat > "${VAULT_F7}/.cache/extracted/papers-attention-pp001-008.md" <<'EOF'
---
title: "Attention Is All You Need"
source_type: "papers"
page_range: "001-008"
---
dummy content
EOF

  # pre-step 은 실제 extract-pdf.sh 가 실행되지 않도록 stub 으로 교체 (PDF 가 존재하지 않으므로 실질 no-op)
  set +e
  out_f7="$(
    PATH="${STUB_DIR}:${PATH}" \
    OBSIDIAN_VAULT="${VAULT_F7}" \
    GIEOK_DRY_RUN=1 \
    GIEOK_EXTRACT_PDF_SCRIPT="${STUB_EXTRACT_F6}" \
    GIEOK_ALLOW_EXTRACT_PDF_OVERRIDE=1 \
    bash "${AUTO_INGEST}" 2>&1
  )"
  rc=$?
  set -e
  assert_eq "0" "${rc}" "F7 exit code 0"
  assert_contains "${out_f7}" "Found 0 unprocessed log(s) and 1 unprocessed raw-source" "F7 counted .cache/extracted MD"

  # ---------------------------------------------------------------------------
  # Test F8: GIEOK_INGEST_MAX_SECONDS=0 즉시 timeout → PDF 루프 break
  # ---------------------------------------------------------------------------
  echo "test F8: GIEOK_INGEST_MAX_SECONDS=0 aborts PDF loop before extraction"
  VAULT_F8="$(make_vault vault-f8)"
  mkdir -p "${VAULT_F8}/raw-sources/papers"
  : > "${VAULT_F8}/raw-sources/papers/deferred.pdf"
  add_unprocessed_log "${VAULT_F8}" "20260417-110000-f8"

  STUB_EXTRACT_F8="${TMPROOT}/stub-extract-f8.sh"
  INVOKED_FILE_F8="${TMPROOT}/extract-f8.invoked"
  cat > "${STUB_EXTRACT_F8}" <<STUB
#!/usr/bin/env bash
# stub: mark invocation
echo invoked > "${INVOKED_FILE_F8}"
exit 0
STUB
  chmod +x "${STUB_EXTRACT_F8}"

  set +e
  out_f8="$(
    PATH="${STUB_DIR}:${PATH}" \
    OBSIDIAN_VAULT="${VAULT_F8}" \
    GIEOK_DRY_RUN=1 \
    GIEOK_INGEST_MAX_SECONDS=0 \
    GIEOK_EXTRACT_PDF_SCRIPT="${STUB_EXTRACT_F8}" \
    GIEOK_ALLOW_EXTRACT_PDF_OVERRIDE=1 \
    bash "${AUTO_INGEST}" 2>&1
  )"
  rc=$?
  set -e
  assert_eq "0" "${rc}" "F8 exit code 0"
  assert_contains "${out_f8}" "soft-timeout" "F8 soft-timeout message emitted"
  if [[ -f "${INVOKED_FILE_F8}" ]]; then
    fail "F8 stub extract-pdf.sh should NOT be invoked when timeout is 0"
  else
    pass "F8 stub extract-pdf.sh was not invoked (timeout triggered before extraction)"
  fi

  # ---------------------------------------------------------------------------
  # Test F9: VULN-004 대책 — GIEOK_EXTRACT_PDF_SCRIPT 가 설정되어 있어도
  #          GIEOK_ALLOW_EXTRACT_PDF_OVERRIDE=1 가 없으면 override 를 거부한다
  # ---------------------------------------------------------------------------
  echo "test F9: env override rejected without GIEOK_ALLOW_EXTRACT_PDF_OVERRIDE"
  VAULT_F9="$(make_vault vault-f9)"
  mkdir -p "${VAULT_F9}/raw-sources/papers"
  : > "${VAULT_F9}/raw-sources/papers/fake.pdf"
  add_unprocessed_log "${VAULT_F9}" "20260417-130000-f9"

  STUB_EXTRACT_F9="${TMPROOT}/stub-extract-f9.sh"
  INVOKED_FILE_F9="${TMPROOT}/extract-f9.invoked"
  cat > "${STUB_EXTRACT_F9}" <<STUB
#!/usr/bin/env bash
# Evil stub: records invocation. It must NOT be called when gate is off.
echo invoked > "${INVOKED_FILE_F9}"
exit 0
STUB
  chmod +x "${STUB_EXTRACT_F9}"

  set +e
  out_f9="$(
    PATH="${STUB_DIR}:${PATH}" \
    OBSIDIAN_VAULT="${VAULT_F9}" \
    GIEOK_DRY_RUN=1 \
    GIEOK_EXTRACT_PDF_SCRIPT="${STUB_EXTRACT_F9}" \
    bash "${AUTO_INGEST}" 2>&1
  )"
  rc=$?
  set -e
  assert_eq "0" "${rc}" "F9 exit code 0"
  assert_contains "${out_f9}" "ignoring override" "F9 override rejection WARN emitted"
  if [[ -f "${INVOKED_FILE_F9}" ]]; then
    fail "F9 evil stub extract-pdf.sh should NOT be invoked when gate is off"
  else
    pass "F9 evil stub extract-pdf.sh was not invoked (override gated)"
  fi
fi

# -----------------------------------------------------------------------------
# 기능 2.1 (MCP trigger + 하드닝) — F10 / F11 / F12
# -----------------------------------------------------------------------------
# F10: chunk MD 의 source_sha256 이 wiki/summaries/ 의 sha256 과 불일치 → 재 Ingest 대상
# F11: 다른 프로세스가 .gieok-mcp.lock 을 보유 (TTL 내) → auto-ingest skip exit 0
# F12: 구 명명 (`<subdir>-<stem>-pp*.md`, 이중 하이픈 없음) 의 기존 chunk 가 깨지지 않고 동작
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test F10: source_sha256 mismatch -> UNPROCESSED_SOURCES increases
# ---------------------------------------------------------------------------
echo "test F10: source_sha256 mismatch between chunk and summary re-ingests"
VAULT_F10="$(make_vault vault-f10)"
mkdir -p "${VAULT_F10}/.cache/extracted" "${VAULT_F10}/wiki/summaries"
# chunk MD 와 동일명 summary 를 준비하고, sha256 이 다르도록 한다.
cat > "${VAULT_F10}/.cache/extracted/papers--foo-pp001-015.md" <<'EOF'
---
title: "Foo"
source_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
page_range: "001-015"
---
chunk body
EOF
cat > "${VAULT_F10}/wiki/summaries/papers--foo-pp001-015.md" <<'EOF'
---
title: "Foo (old summary)"
source_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
---
old summary
EOF
set +e
out_f10="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F10}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_EXTRACT_PDF_SCRIPT="/nonexistent-ignored" \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F10 exit code 0"
assert_contains "${out_f10}" "Found 0 unprocessed log(s) and 1 unprocessed raw-source" "F10 mismatch counted as unprocessed"

# F10b: sha256 일치하면 미처리로 취급하지 않음
VAULT_F10B="$(make_vault vault-f10b)"
mkdir -p "${VAULT_F10B}/.cache/extracted" "${VAULT_F10B}/wiki/summaries"
cat > "${VAULT_F10B}/.cache/extracted/papers--bar-pp001-010.md" <<'EOF'
---
title: "Bar"
source_sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
---
chunk
EOF
cat > "${VAULT_F10B}/wiki/summaries/papers--bar-pp001-010.md" <<'EOF'
---
title: "Bar summary"
source_sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
---
summary
EOF
set +e
out_f10b="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F10B}" \
  GIEOK_DRY_RUN=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F10b exit code 0"
assert_contains "${out_f10b}" "No unprocessed logs or raw-sources" "F10b matching sha256 not re-ingested"

# ---------------------------------------------------------------------------
# Test F11: .gieok-mcp.lock held by another process -> skip exit 0
# ---------------------------------------------------------------------------
echo "test F11: lockfile held by another writer -> skip exit 0"
VAULT_F11="$(make_vault vault-f11)"
add_unprocessed_log "${VAULT_F11}" "20260417-200000-f11"
# 다른 프로세스가 보유 중인 상황을 모의: 신선한 lockfile 을 직접 만든다
printf '%s %s\n' "99999" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${VAULT_F11}/.gieok-mcp.lock"
set +e
out_f11="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F11}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_LOCK_ACQUIRE_TIMEOUT=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F11 exit code 0 when lock held"
assert_contains "${out_f11}" "another writer holds" "F11 lock-held message emitted"
# stub claude 가 호출되지 않았을 것 (ingest 경로에 진입하지 않음)
if printf '%s' "${out_f11}" | grep -q "DRY RUN: would call claude"; then
  fail "F11 ingest should have been skipped by lock"
else
  pass "F11 ingest path was not entered"
fi
# lockfile 을 다른 프로세스의 것으로 남겨둬도, auto-ingest 는 자신의 것이 아니므로 unlink 하지 않음
if [[ -f "${VAULT_F11}/.gieok-mcp.lock" ]]; then
  pass "F11 foreign lock preserved (not unlinked by failed acquire)"
else
  fail "F11 foreign lock was unexpectedly removed"
fi

# F11b: stale lockfile (TTL 초과) 은 자동 회수됨
echo "test F11b: stale lockfile (past TTL) auto-recovered"
VAULT_F11B="$(make_vault vault-f11b)"
add_unprocessed_log "${VAULT_F11B}" "20260417-210000-f11b"
touch "${VAULT_F11B}/.gieok-mcp.lock"
# lockfile 의 mtime 을 과거로 설정 (2시간 전)
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)" \
  "${VAULT_F11B}/.gieok-mcp.lock"
(cd "${VAULT_F11B}" && git init --quiet && git -c user.email=t@test -c user.name=t commit --allow-empty -m init --quiet)
set +e
out_f11b="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F11B}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_LOCK_TTL_SECONDS=60 \
  GIEOK_LOCK_ACQUIRE_TIMEOUT=2 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F11b exit code 0 (stale lock recovered)"
assert_contains "${out_f11b}" "DRY RUN: would call claude" "F11b ingest path reached after stale lock recovery"

# ---------------------------------------------------------------------------
# Test F12: legacy single-hyphen chunk naming remains compatible
# ---------------------------------------------------------------------------
echo "test F12: legacy chunk naming (<subdir>-<stem>-pp*.md) still counted"
VAULT_F12="$(make_vault vault-f12)"
mkdir -p "${VAULT_F12}/.cache/extracted"
# Legacy chunk without source_sha256 and without matching summary → unprocessed
cat > "${VAULT_F12}/.cache/extracted/papers-legacy-pp001-008.md" <<'EOF'
---
title: "Legacy"
page_range: "001-008"
---
legacy body
EOF
set +e
out_f12="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F12}" \
  GIEOK_DRY_RUN=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F12 exit code 0"
assert_contains "${out_f12}" "Found 0 unprocessed log(s) and 1 unprocessed raw-source" "F12 legacy chunk counted as unprocessed"

# -----------------------------------------------------------------------------
# 기능 2.2 (HTML/URL ingest) — F13 / F14 / F15 / F16 / F17 / F18
# -----------------------------------------------------------------------------
# F13: urls.txt 가 1행 URL → extract-url.sh 가 argv 로 urls-file 지정하여 호출됨
# F14: 주석 / 빈 줄 혼합된 urls.txt → cron 은 1파일 = 1 invocation 으로 전달
#      (실제 "1 URL 만 실행" 판정은 extract-url.sh / urls-txt-parser 쪽이므로
#      여기서는 extract-url.sh 가 **정확히 1회** 호출되는 것만 assert 한다)
# F15: DSL 행 (url ; tags=foo,bar) 을 포함한 urls.txt → cron 은 file 을 그대로 전달.
#      stub 의 argv 에 urls.txt 의 경로가 전달되는 것만 assert 한다 (DSL parsing 은 downstream)
# F16: 이미 fetched/<slug>.md + sha 일치 → cron 은 extract-url.sh 를 호출한다 (skip 판정은 CLI 쪽)
# F17: REFRESH_DAYS 경과 → CLI 쪽에서 re-fetch, cron 계층에서는 관여하지 않으므로 MCP unit 에 위임 (pass)
# F18: GIEOK_INGEST_MAX_SECONDS=0 → URL pre-step 즉시 break, stub 호출 안 됨
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test F13: urls.txt 1행 URL → extract-url.sh 가 urls-file argv 와 함께 호출됨
# ---------------------------------------------------------------------------
echo "test F13: urls.txt -> extract-url.sh invoked with --urls-file"
VAULT_F13="$(make_vault vault-f13)"
mkdir -p "${VAULT_F13}/raw-sources/articles"
cat > "${VAULT_F13}/raw-sources/articles/urls.txt" <<'EOF'
https://example.com/a
EOF
add_unprocessed_log "${VAULT_F13}" "20260419-100000-f13"

STUB_EXTRACT_URL_F13="${TMPROOT}/stub-extract-url-f13.sh"
ARGS_FILE_F13="${TMPROOT}/extract-url-f13.args"
cat > "${STUB_EXTRACT_URL_F13}" <<STUB
#!/usr/bin/env bash
printf 'argv: %s\n' "\$*" >> "${ARGS_FILE_F13}"
exit 0
STUB
chmod +x "${STUB_EXTRACT_URL_F13}"

set +e
out_f13="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F13}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_EXTRACT_URL_SCRIPT="${STUB_EXTRACT_URL_F13}" \
  GIEOK_ALLOW_EXTRACT_URL_OVERRIDE=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
rc=$?
set -e
assert_eq "0" "${rc}" "F13 exit 0"
if [[ -f "${ARGS_FILE_F13}" ]]; then
  pass "F13 extract-url stub invoked"
  args_f13="$(cat "${ARGS_FILE_F13}")"
  assert_contains "${args_f13}" "--urls-file" "F13 --urls-file flag passed"
  assert_contains "${args_f13}" "raw-sources/articles/urls.txt" "F13 urls.txt path passed"
  assert_contains "${args_f13}" "--vault" "F13 --vault flag passed"
  assert_contains "${args_f13}" "--subdir" "F13 --subdir flag passed"
  assert_contains "${args_f13}" "articles" "F13 subdir name (articles) passed"
else
  fail "F13 extract-url stub not invoked"
fi

# ---------------------------------------------------------------------------
# Test F14: 주석 / 빈 줄을 포함한 urls.txt → cron 은 1 file = 1 call 로 전달
# (DSL parsing / 주석 skip 은 extract-url.sh 쪽, urls-txt-parser.test.mjs 에서 보장)
# ---------------------------------------------------------------------------
echo "test F14: urls.txt with comments -> 1 call to extract-url.sh (parsing is downstream)"
VAULT_F14="$(make_vault vault-f14)"
mkdir -p "${VAULT_F14}/raw-sources/articles"
cat > "${VAULT_F14}/raw-sources/articles/urls.txt" <<'EOF'
# this is a comment

https://example.com/real
# another comment
EOF
add_unprocessed_log "${VAULT_F14}" "20260419-110000-f14"

STUB_EXTRACT_URL_F14="${TMPROOT}/stub-extract-url-f14.sh"
ARGS_FILE_F14="${TMPROOT}/extract-url-f14.args"
cat > "${STUB_EXTRACT_URL_F14}" <<STUB
#!/usr/bin/env bash
printf 'argv: %s\n' "\$*" >> "${ARGS_FILE_F14}"
exit 0
STUB
chmod +x "${STUB_EXTRACT_URL_F14}"

set +e
PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F14}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_EXTRACT_URL_SCRIPT="${STUB_EXTRACT_URL_F14}" \
  GIEOK_ALLOW_EXTRACT_URL_OVERRIDE=1 \
  bash "${AUTO_INGEST}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "0" "${rc}" "F14 exit 0"
# extract-url.sh 는 1 urls.txt 당 1회만 호출됨 (file 자체의 comment skip 은 downstream)
# set +e 는 grep 이 0 히트 (= rc 1) 일 때 pipeline 이 trip 되지 않도록 일시 퇴피
set +e
n_calls_f14=$(grep -c "argv:" "${ARGS_FILE_F14}" 2>/dev/null)
set -e
n_calls_f14="${n_calls_f14:-0}"
assert_eq "1" "${n_calls_f14}" "F14 extract-url.sh invoked exactly 1 time per urls.txt"

# ---------------------------------------------------------------------------
# Test F15: DSL 행 (url ; tags=foo,bar) 을 포함한 urls.txt → cron 은 file path 만 전달
# (DSL → --tags 변환은 extract-url.sh 내, urls-txt-parser.test.mjs 에서 보장)
# 여기서는 cron 계층이 urls.txt 의 path 를 올바르게 전달할 수 있는지만 assert
# ---------------------------------------------------------------------------
echo "test F15: urls.txt with DSL row -> file path passed (DSL parsing is downstream)"
VAULT_F15="$(make_vault vault-f15)"
mkdir -p "${VAULT_F15}/raw-sources/articles"
cat > "${VAULT_F15}/raw-sources/articles/urls.txt" <<'EOF'
https://example.com/tagged ; tags=foo,bar
EOF
add_unprocessed_log "${VAULT_F15}" "20260419-120000-f15"

STUB_EXTRACT_URL_F15="${TMPROOT}/stub-extract-url-f15.sh"
ARGS_FILE_F15="${TMPROOT}/extract-url-f15.args"
cat > "${STUB_EXTRACT_URL_F15}" <<STUB
#!/usr/bin/env bash
printf 'argv: %s\n' "\$*" >> "${ARGS_FILE_F15}"
exit 0
STUB
chmod +x "${STUB_EXTRACT_URL_F15}"

set +e
PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F15}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_EXTRACT_URL_SCRIPT="${STUB_EXTRACT_URL_F15}" \
  GIEOK_ALLOW_EXTRACT_URL_OVERRIDE=1 \
  bash "${AUTO_INGEST}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "0" "${rc}" "F15 exit 0"
args_f15="$(cat "${ARGS_FILE_F15}" 2>/dev/null || echo '')"
assert_contains "${args_f15}" "raw-sources/articles/urls.txt" "F15 urls.txt path passed (DSL parsing downstream)"

# ---------------------------------------------------------------------------
# Test F16: fetched/<slug>.md 가 기존 + sha 일치 → cron 은 extract-url.sh 를 호출
# (re-fetch skip 판정은 CLI 쪽; 여기서는 cron 이 호출하는 것만 확인)
# ---------------------------------------------------------------------------
echo "test F16: existing fetched MD + sha match → extract-url.sh still invoked by cron"
VAULT_F16="$(make_vault vault-f16)"
mkdir -p "${VAULT_F16}/raw-sources/articles/fetched"
cat > "${VAULT_F16}/raw-sources/articles/fetched/example.com-done.md" <<'EOF'
---
source_url: "https://example.com/done"
source_sha256: "aaa"
fetched_at: "2026-04-19T00:00:00Z"
refresh_days: 30
---
body
EOF
cat > "${VAULT_F16}/raw-sources/articles/urls.txt" <<'EOF'
https://example.com/done
EOF
STUB_EXTRACT_URL_F16="${TMPROOT}/stub-extract-url-f16.sh"
CALL_LOG_F16="${TMPROOT}/extract-url-f16.called"
cat > "${STUB_EXTRACT_URL_F16}" <<STUB
#!/usr/bin/env bash
echo called >> "${CALL_LOG_F16}"
exit 0
STUB
chmod +x "${STUB_EXTRACT_URL_F16}"
set +e
PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F16}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_EXTRACT_URL_SCRIPT="${STUB_EXTRACT_URL_F16}" \
  GIEOK_ALLOW_EXTRACT_URL_OVERRIDE=1 \
  bash "${AUTO_INGEST}" >/dev/null 2>&1
set -e
# cron 쪽에서는 skip 판정을 하지 않으므로, extract-url.sh 는 호출된다 (skip 판정은 CLI 내부)
assert_contains "$(cat ${CALL_LOG_F16} 2>/dev/null || echo '')" "called" "F16 URL pre-step attempted (CLI handles re-fetch skip)"

# ---------------------------------------------------------------------------
# Test F17: REFRESH_DAYS 경과 시의 re-fetch 는 CLI 쪽 담당 → MCP unit test 로 위임
# ---------------------------------------------------------------------------
echo "test F17: skipped — see MCP40 in tools-ingest-url.test.mjs (CLI-level concern)"
pass "F17 see MCP unit tests"

# ---------------------------------------------------------------------------
# Test F18: GIEOK_INGEST_MAX_SECONDS=0 → URL pre-step 즉시 break, stub 호출 안 됨
# ---------------------------------------------------------------------------
echo "test F18: GIEOK_INGEST_MAX_SECONDS=0 → URL loop breaks before stub invocation"
VAULT_F18="$(make_vault vault-f18)"
mkdir -p "${VAULT_F18}/raw-sources/articles"
cat > "${VAULT_F18}/raw-sources/articles/urls.txt" <<'EOF'
https://example.com/should-not-be-fetched
EOF
add_unprocessed_log "${VAULT_F18}" "20260419-130000-f18"

STUB_EXTRACT_URL_F18="${TMPROOT}/stub-extract-url-f18.sh"
INVOKED_F18="${TMPROOT}/extract-url-f18.invoked"
cat > "${STUB_EXTRACT_URL_F18}" <<STUB
#!/usr/bin/env bash
echo called > "${INVOKED_F18}"
exit 0
STUB
chmod +x "${STUB_EXTRACT_URL_F18}"

set +e
out_f18="$(
  PATH="${STUB_DIR}:${PATH}" \
  OBSIDIAN_VAULT="${VAULT_F18}" \
  GIEOK_DRY_RUN=1 \
  GIEOK_INGEST_MAX_SECONDS=0 \
  GIEOK_EXTRACT_URL_SCRIPT="${STUB_EXTRACT_URL_F18}" \
  GIEOK_ALLOW_EXTRACT_URL_OVERRIDE=1 \
  bash "${AUTO_INGEST}" 2>&1
)"
set -e
if [[ -f "${INVOKED_F18}" ]]; then
  fail "F18 extract-url should NOT be invoked when soft-timeout is 0"
else
  pass "F18 soft-timeout prevents URL fetch"
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
