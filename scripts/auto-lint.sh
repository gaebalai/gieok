#!/usr/bin/env bash
#
# auto-lint.sh — claude-brain 자동 lint 스크립트 (Phase G)
#
# cron 에서 호출되어 wiki/ 의 건전성 리포트를 wiki/lint-report.md 로 출력한다.
# 리포트 생성만 하며 자동 수정은 하지 않는다 (--allowedTools 에 Edit 을 포함하지 않음).
#
# 환경 변수:
#   OBSIDIAN_VAULT   Vault 루트 (미설정 시 $HOME/claude-brain/main-claude-brain)
#   GIEOK_DRY_RUN=1  claude -p 를 호출하지 않고 명령을 로그에만 출력 (테스트용)
#
# 종료 코드:
#   0  정상 종료 (페이지 0건의 스킵 포함)
#   1  Vault 가 존재하지 않음 / claude 명령이 PATH 에 없음
#
# 사용 예 (crontab):
#   0 8 1 * * /ABS/PATH/to/auto-lint.sh >> "$HOME/gieok-lint.log" 2>&1

set -euo pipefail

LOG_PREFIX="[auto-lint $(date +%Y%m%d-%H%M)]"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-${HOME}/claude-brain/main-claude-brain}"

# R4-001: OBSIDIAN_VAULT 유효성 검증
validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ $safe_re ]]; then
    echo "${LOG_PREFIX} ERROR: OBSIDIAN_VAULT contains unsafe characters: ${p}" >&2
    exit 1
  fi
}
validate_vault_path "${OBSIDIAN_VAULT}"

# Volta 관리하의 바이너리 (~/.volta/bin) 와 mise shims (~/.local/share/mise/shims) 도 포함.
#
# 중요: mise shims 를 Volta 보다 **먼저** 놓는다. qmd 는 mise 의 Node 22 에 대해
# native module (better-sqlite3) 을 빌드하므로 Volta 상의 다른 버전의
# Node 가 PATH 선두에 있으면 ABI mismatch 로 크래시한다.
# claude (Volta 관리) 는 mise shim 상에 존재하지 않으므로 여전히 Volta 에서 발견된다.
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.volta/bin:${HOME}/.local/bin:${HOME}/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if [[ ! -d "${OBSIDIAN_VAULT}" ]]; then
  echo "${LOG_PREFIX} ERROR: OBSIDIAN_VAULT not found: ${OBSIDIAN_VAULT}" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "${LOG_PREFIX} ERROR: claude command not found in PATH" >&2
  exit 1
fi

# VULN-011: PATH 상의 바이너리가 소유자 이외에게 쓰기 가능하지 않은지 검증
# NEW-005: ls -ln + awk 로 POSIX 이식성 확보 (macOS / Linux 양쪽 대응)
for bin_name in claude node; do
  bin_path="$(command -v "${bin_name}" 2>/dev/null || true)"
  if [[ -n "${bin_path}" ]] && [[ -w "${bin_path}" ]]; then
    owner_uid="$(ls -ln "${bin_path}" 2>/dev/null | awk '{print $3}')"
    if [[ -n "${owner_uid}" ]] && [[ "${owner_uid}" != "$(id -u)" ]]; then
      echo "${LOG_PREFIX} WARNING: ${bin_name} at ${bin_path} is writable by non-owner" >&2
    fi
  fi
done

# -----------------------------------------------------------------------------
# wiki 페이지 수 확인 (index.md / log.md / lint-report.md 은 대상 외)
#
# 2026-04-20 HIGH-b2 fix (documentation): lint 의 스캔 대상은 wiki/ 로만 한정.
# 향후 R1 (Unicode 불가시 문자 검출) 을 Vault 루트로 확장할 경우 반드시 아래를 제외:
#   - .cache/html/     : 기능 2.2 가 저장하는 attacker-controlled raw HTML
#                        (invisible-char 오탐 / DoS 유도 방지)
#   - .cache/extracted/: PDF chunk (마스킹 완료이나 대량 생성)
#   - raw-sources/**/fetched/media/ : 이미지 바이너리
# -----------------------------------------------------------------------------

WIKI_DIR="${OBSIDIAN_VAULT}/wiki"
if [[ ! -d "${WIKI_DIR}" ]]; then
  echo "${LOG_PREFIX} No wiki directory yet. Skipping."
  exit 0
fi

WIKI_PAGES=0
while IFS= read -r _; do
  WIKI_PAGES=$((WIKI_PAGES + 1))
done < <(
  find "${WIKI_DIR}" -type f -name "*.md" \
    ! -name "index.md" ! -name "log.md" ! -name "lint-report.md" 2>/dev/null
)

if [[ "${WIKI_PAGES}" == "0" ]]; then
  echo "${LOG_PREFIX} Wiki has no content pages yet. Skipping lint."
  exit 0
fi

echo "${LOG_PREFIX} Found ${WIKI_PAGES} wiki page(s). Starting lint..."

# -----------------------------------------------------------------------------
# Git pull (최신 wiki 를 체크 대상으로 삼는다)
# -----------------------------------------------------------------------------

cd "${OBSIDIAN_VAULT}"
git pull --rebase --quiet 2>/dev/null || true

# -----------------------------------------------------------------------------
# R1 (기능 2.1 / VULN-014 감사층): Unicode 불가시 문자의 사전 스캔
# -----------------------------------------------------------------------------
# ZWSP / RTLO / SHY / BOM 등 비표시 Unicode 가 wiki/ 의 .md 에 혼입되어 있는지
# 셸 쪽에서 검출하여 결과를 LINT_PROMPT 에 주입한다. LLM 은 R1 섹션을 lint-report.md
# 에 적어 사람이 prompt injection 의심을 리뷰할 수 있도록 한다.
#
# - 검출만 수행, 자동 수정 없음 (오수정 사고 방지)
# - LC_ALL=C grep -P 는 BSD grep 미대응이므로 Node 내장 정규식으로 구현
# - node 가 PATH 에 없는 환경에서는 R1 은 WARN 을 내고 skip (기존 rule 은 계속 동작)
R1_FINDINGS=""
if command -v node >/dev/null 2>&1; then
  # node -e 는 세션 환경의 OBSIDIAN_VAULT 에 의존시키지 않기 위해 wiki 디렉터리를
  # 제1 인자로 명시적으로 전달.
  R1_FINDINGS="$(
    node -e '
      const { readFileSync } = require("node:fs");
      const { createInterface } = require("node:readline");
      const wiki = process.argv[1];
      // Unicode 불가시/제어 문자: SHY, ZWSP 계열, bidi override 계열, word joiner 계열, BOM
      const RE = /[\u00AD\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/;
      const rl = createInterface({ input: process.stdin });
      rl.on("line", (abs) => {
        if (!abs) return;
        let content;
        try { content = readFileSync(abs, "utf8"); } catch { return; }
        const lines = content.split("\n");
        const hits = [];
        for (let i = 0; i < lines.length; i++) {
          if (RE.test(lines[i])) hits.push(i + 1);
        }
        if (hits.length) {
          const rel = abs.startsWith(wiki + "/") ? abs.slice(wiki.length + 1) : abs;
          // LOW-1 대책 (기능 2.1 security review): rel 은 파일명 유래이므로
          // 백틱 / 개행 / `$` / 백슬래시 등이 포함되면
          // LINT_PROMPT 말미의 findings 섹션을 탈출해 LLM prompt 를 오염시킬 수 있다.
          // 이러한 문자는 "?" 로 치환해 prompt injection 경로를 막는다.
          const safeRel = rel.replace(/[`\n\r\\$]/g, "?");
          process.stdout.write(`- \`wiki/${safeRel}\` (lines ${hits.join(",")})\n`);
        }
      });
    ' "${WIKI_DIR}" < <(
      find "${WIKI_DIR}" -type f -name '*.md' \
        ! -name 'lint-report.md' 2>/dev/null
    ) 2>/dev/null || true
  )"
else
  echo "${LOG_PREFIX} WARN: node not in PATH; R1 (Unicode invisible char scan) skipped" >&2
fi

# -----------------------------------------------------------------------------
# 린트 프롬프트
# -----------------------------------------------------------------------------

read -r -d '' LINT_PROMPT <<'PROMPT' || true
CLAUDE.md 의 스키마에 따라 wiki/ 내 모든 파일을 읽고 건전성을 체크해 주세요.

아래 관점에서 문제를 찾으세요:
1. 페이지 간 모순 (같은 사실에 대해 다른 기술이 없는지)
2. 고립 페이지 (다른 어느 페이지에서도 링크되지 않은 페이지)
3. 반복적으로 언급되지만 전용 페이지가 없는 개념
4. 새로운 소스로 덮어쓰기된 오래된 주장
5. 부족한 상호 링크
6. 프런트매터의 불비 (tags, updated 등의 누락)

중요: 문제 수정은 수행하지 말 것. 리포트 생성만.

출력처: wiki/lint-report.md
포맷:
---
title: Lint Report
date: (오늘 날짜)
---

# Wiki Lint Report (YYYY-MM-DD)

## 요약
- 검출한 문제의 총수
- 카테고리별 내역

## 모순
(모순이 있다면 구체적인 페이지명과 내용을 열거)

## 고립 페이지
(링크되지 않은 페이지 목록)

## 전용 페이지 후보
(빈출이지만 전용 페이지가 없는 개념)

## 오래된 기술 의심
(새로운 정보로 덮어쓰기되었을 가능성이 있는 기술)

## 링크 부족
(상호 링크를 추가해야 할 곳)

## 프런트매터 불비
(불비가 있는 페이지 목록)

## R1: Unicode 불가시 문자 (prompt injection 감사)
(셸 측 pre-scan 결과가 프롬프트 말미에서 제공되므로 그것을 그대로 열거한다.
해당 페이지가 없으면 「검출 없음」이라고 기재. ZWSP / RTLO / SHY / BOM 등의 불가시 문자는
PDF 유래 텍스트에 혼입될 수 있고, LLM 에 대한 지시 삽입 수단이 될 수 있으므로
페이지명과 행 번호를 명시해 두면 사람이 리뷰하기 쉽다. 자동 수정은 하지 말 것.)
PROMPT

# 동적 R1 findings 를 LINT_PROMPT 말미에 추가. findings 가 비어 있는 경우에도 명시 섹션을
# 만들어 LLM 이 「검출 없음」을 기재할 수 있게 한다.
LINT_PROMPT+="

---

### R1 pre-scan findings (셸이 측정한 결과, LLM 측 재측정 불필요)
"
if [[ -n "${R1_FINDINGS}" ]]; then
  LINT_PROMPT+="${R1_FINDINGS}"
else
  LINT_PROMPT+="(해당 없음 — wiki/ 내의 어떤 .md 에서도 ZWSP / RTLO / SHY / BOM 등은 검출되지 않았습니다)"
fi

# -----------------------------------------------------------------------------
# 린트 실행 (테스트에서 mock 가능하도록 함수화)
# Write 만 허용. Edit 은 허용하지 않음 = wiki 의 기존 파일을 수정할 수 없다.
# -----------------------------------------------------------------------------

run_lint() {
  if [[ "${GIEOK_DRY_RUN:-0}" == "1" ]]; then
    echo "${LOG_PREFIX} DRY RUN: would call claude -p with prompt len=${#LINT_PROMPT}"
    # DRY RUN 시에도 리포트 파일 존재 확인 테스트를 위해 더미를 쓴다
    mkdir -p "${WIKI_DIR}"
    printf -- '---\ntitle: Lint Report (dry run)\ndate: %s\n---\n' "$(date +%Y-%m-%d)" \
      > "${WIKI_DIR}/lint-report.md"
    return 0
  fi
  # GIEOK_NO_LOG=1 로 서브프로세스 측 훅을 no-op 화 (재귀 로그 방지).
  GIEOK_NO_LOG=1 claude -p "${LINT_PROMPT}" \
    --allowedTools Write,Read \
    --max-turns 30
}

run_lint

# -----------------------------------------------------------------------------
# lint-report.md 를 commit & push
# DRY RUN 시에는 건너뛴다 (stub 을 커밋하지 않기 위해).
# Vault 가 git 리포지터리가 아니어도 건너뛴다.
# -----------------------------------------------------------------------------

if [[ "${GIEOK_DRY_RUN:-0}" == "1" ]]; then
  echo "${LOG_PREFIX} DRY RUN: skipping git commit/push."
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # R4-006: .gitignore 에 session-logs/ 가 포함되어 있는지 확인한 뒤 git 작업
  if ! grep -q '^session-logs/' .gitignore 2>/dev/null; then
    echo "${LOG_PREFIX} WARNING: .gitignore missing 'session-logs/' entry. Skipping git commit/push for safety." >&2
  else
    git add wiki/lint-report.md 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
      echo "${LOG_PREFIX} No changes to lint report."
    else
      git commit -m "auto-lint: report $(date +%Y%m%d)" --quiet 2>/dev/null || true
      git push --quiet 2>/dev/null || true
      echo "${LOG_PREFIX} Lint report generated and pushed."
    fi
  fi
else
  echo "${LOG_PREFIX} Vault is not a git repository. Skipping commit/push."
fi

# -----------------------------------------------------------------------------
# Phase J: qmd 인덱스 갱신 (설치되어 있는 경우만)
#
# lint 리포트도 qmd 의 검색 대상에 포함시키기 위해 여기서 재인덱싱한다.
# qmd 미설치 시에는 아무것도 하지 않는다 (옵션 의존).
# -----------------------------------------------------------------------------

if command -v qmd >/dev/null 2>&1; then
  echo "${LOG_PREFIX} Updating qmd index..."
  qmd update >/dev/null 2>&1 || echo "${LOG_PREFIX} [warn] qmd update failed"
  qmd embed  >/dev/null 2>&1 || echo "${LOG_PREFIX} [warn] qmd embed failed"
else
  echo "${LOG_PREFIX} qmd not installed; skipping index update."
fi

# -----------------------------------------------------------------------------
# 자가 진단 섹션 (open-issues #4 / #5 / #6 통합)
#
# - 월간 lint 의 말미에서 3종의 건전성 체크를 한꺼번에 실행하고 stdout 에 요약한다.
# - 결과는 $HOME/gieok-lint.log (cron 리다이렉트 대상) 에 남으므로
#   사용자는 월 1회 로그를 보는 것만으로 아래를 파악할 수 있다:
#     1. auto-ingest 가 max_turns 상한에 도달했는지 (#4)
#     2. wiki/lint-report.md 가 새로 몇 건의 문제를 보고했는지 (#5)
#     3. session-logs/ 에 비밀 정보 누출이 있는지 (#6)
# - 진단 자체는 정보 제시뿐이며 exit code 는 실패로 취급하지 않는다 (기존 cron 동작 유지).
# -----------------------------------------------------------------------------

run_self_diagnostics() {
  echo "${LOG_PREFIX} --- self-diagnostics ---"

  # (1) auto-ingest 의 max_turns 도달을 감지
  # GIEOK_INGEST_LOG 로 교체 가능 (테스트용). 기본값은 cron 의 리다이렉트 대상.
  local ingest_log="${GIEOK_INGEST_LOG:-${HOME}/gieok-ingest.log}"
  if [[ -f "${ingest_log}" ]]; then
    local max_turn_hits
    max_turn_hits=$(grep -ciE 'max.?turns?' "${ingest_log}" 2>/dev/null || true)
    max_turn_hits="${max_turn_hits:-0}"
    if [[ "${max_turn_hits}" -gt 0 ]]; then
      echo "${LOG_PREFIX} [#4] WARNING: 'max turns' mentioned ${max_turn_hits} time(s) in ${ingest_log}"
      echo "${LOG_PREFIX} [#4] Consider raising --max-turns in auto-ingest.sh."
    else
      echo "${LOG_PREFIX} [#4] OK: no max_turns saturation in ingest log."
    fi
  else
    echo "${LOG_PREFIX} [#4] SKIP: ingest log not found at ${ingest_log}"
  fi

  # (2) lint-report.md 의 문제 총수를 추출
  #
  # 프롬프트 사양상 리포트에는 「## 요약」과 「검출한 문제의 총수」가 적힌다.
  # Claude 출력의 편차를 허용하기 위해 숫자를 포함한 행을 폭넓게 수집한다.
  local report_file="${WIKI_DIR}/lint-report.md"
  if [[ -f "${report_file}" ]]; then
    # 「요약」 섹션 바로 아래에서 숫자를 추출하는 단순 방식. 찾지 못하면 건수 불명 취급.
    local summary_line
    summary_line=$(grep -m1 -iE '(검출|합계|total|문제의 총수|문제수)' "${report_file}" 2>/dev/null || true)
    if [[ -n "${summary_line}" ]]; then
      echo "${LOG_PREFIX} [#5] lint-report.md summary: ${summary_line}"
    else
      local line_count
      line_count=$(wc -l < "${report_file}" | tr -d ' ')
      echo "${LOG_PREFIX} [#5] lint-report.md exists (${line_count} lines). Review in Obsidian."
    fi
  else
    echo "${LOG_PREFIX} [#5] SKIP: lint-report.md not generated yet."
  fi

  # (3) scan-secrets.sh 로 session-logs/ 의 누출을 감지
  #
  # 스크립트는 존재 체크로 optional 취급 (형제 스크립트가 동작하지 않는 환경에서도
  # auto-lint 가 깨지지 않도록).
  local scan_script="${SCRIPT_DIR}/scan-secrets.sh"
  if [[ -f "${scan_script}" ]]; then
    set +e
    local scan_out
    scan_out=$(OBSIDIAN_VAULT="${OBSIDIAN_VAULT}" bash "${scan_script}" 2>&1)
    local scan_rc=$?
    set -e
    case "${scan_rc}" in
      0)
        echo "${LOG_PREFIX} [#6] OK: session-logs/ clean."
        ;;
      2)
        echo "${LOG_PREFIX} [#6] WARNING: secret-like patterns detected in session-logs/"
        printf '%s\n' "${scan_out}" | sed "s/^/${LOG_PREFIX} [#6]   /"
        ;;
      *)
        echo "${LOG_PREFIX} [#6] SKIP: scan-secrets.sh exit ${scan_rc} (vault or session-logs/ missing)"
        ;;
    esac
  else
    echo "${LOG_PREFIX} [#6] SKIP: scan-secrets.sh not found at ${scan_script}"
  fi

  # (4) 기능 2.2 operator 알림 플래그 (MED-d3 fix, 2026-04-20)
  #
  # gieok_ingest_url 이 GIEOK_URL_ALLOW_LOOPBACK=1 / GIEOK_URL_IGNORE_ROBOTS=1 을
  # 프로덕션 (비테스트 / 비 MCP child) 에서 감지한 경우 $VAULT/.gieok-alerts/
  # 에 timestamp flag 를 쓴다. stderr WARN 은 cron / launchd 로그에 묻히므로
  # 여기서 lint 로그를 통해 operator 의 시인성을 높인다.
  local alerts_dir="${OBSIDIAN_VAULT}/.gieok-alerts"
  if [[ -d "${alerts_dir}" ]]; then
    local flag_count
    flag_count=$(find "${alerts_dir}" -type f -name '*.flag' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${flag_count}" -gt 0 ]]; then
      echo "${LOG_PREFIX} [#7] WARNING: ${flag_count} operator alert flag(s) in ${alerts_dir}"
      while IFS= read -r flag; do
        local name ts
        name="$(basename "${flag}" .flag)"
        ts="$(head -n1 "${flag}" 2>/dev/null || echo '?')"
        echo "${LOG_PREFIX} [#7]   ${name}: ${ts}"
      done < <(find "${alerts_dir}" -type f -name '*.flag' 2>/dev/null)
      echo "${LOG_PREFIX} [#7] Review test flags leaked to production (SSRF / robots bypass). Clear with: rm ${alerts_dir}/*.flag"
    else
      echo "${LOG_PREFIX} [#7] OK: no operator alert flags."
    fi
  else
    echo "${LOG_PREFIX} [#7] SKIP: no .gieok-alerts/ directory (never alerted)."
  fi

  echo "${LOG_PREFIX} --- end diagnostics ---"
}

# DRY RUN 에서도 진단은 돌려서 경로를 확인한다 (부작용이 없으므로).
run_self_diagnostics

echo "${LOG_PREFIX} Done. Review wiki/lint-report.md in Obsidian."
