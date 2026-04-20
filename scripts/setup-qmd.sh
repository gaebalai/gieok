#!/usr/bin/env bash
#
# setup-qmd.sh — claude-brain Phase J: qmd wiki 검색 셋업
#
# Vault 하위의 wiki / raw-sources / session-logs 를 qmd 의 컬렉션으로 등록하고
# 최초 BM25 인덱스 + 벡터 임베딩을 생성한다. MCP 서버 기동은
# install-qmd-daemon.sh 가 담당한다.
#
# 환경 변수:
#   OBSIDIAN_VAULT  Vault 루트 (미설정 시 $HOME/claude-brain/main-claude-brain)
#   GIEOK_QMD_SKIP_EMBED=1  벡터 임베딩 생성을 건너뜀 (테스트용)
#
# 종료 코드:
#   0  정상 종료 (이미 컬렉션이 등록되어 있어도 0)
#   1  Vault 부재 / qmd 명령이 PATH 에 없음
#
# qmd 설치:
#   npm install -g @tobilu/qmd
#   (이 스크립트는 자동 설치하지 않는다. 사전에 수동으로 도입할 것)

set -euo pipefail

LOG_PREFIX="[setup-qmd $(date +%Y%m%d-%H%M)]"

# NEW-008: --include-logs 플래그로 brain-logs 컬렉션 등록을 opt-in 으로 바꾼다
INCLUDE_LOGS=0
for arg in "$@"; do
  case "${arg}" in
    --include-logs) INCLUDE_LOGS=1 ;;
    -h|--help)
      echo "Usage: bash setup-qmd.sh [--include-logs]"
      echo "  --include-logs  Register session-logs/ as a qmd collection (opt-in)"
      exit 0
      ;;
  esac
done

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

# cron 이나 비대화형 셸에서도 qmd 를 찾을 수 있도록 mise shims / Volta 를 보완한다.
#
# 중요: ~/.local/share/mise/shims 를 ~/.volta/bin 보다 **먼저** 놓는다.
# qmd 는 mise 의 Node 22 에 native module (better-sqlite3) 을 빌드해 두었기 때문에
# Volta 의 다른 버전의 Node 가 PATH 선두에 있으면 ABI mismatch 로 크래시한다
# (NODE_MODULE_VERSION 127 vs 141 등).
# mise shim 은 부모 PATH 상의 `node` 를 그대로 사용하는 구현이므로 PATH 순서로 흡수한다.
export PATH="${HOME}/.local/share/mise/shims:${HOME}/.volta/bin:${HOME}/.local/bin:${HOME}/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if [[ ! -d "${OBSIDIAN_VAULT}" ]]; then
  echo "${LOG_PREFIX} ERROR: OBSIDIAN_VAULT not found: ${OBSIDIAN_VAULT}" >&2
  exit 1
fi

if ! command -v qmd >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: qmd command not found in PATH.

Install qmd first (any of):

  npm install -g @tobilu/qmd       # Volta / system Node
  mise use -g npm:@tobilu/qmd      # mise

Reference: https://github.com/tobi/qmd
EOF
  exit 1
fi

echo "============================================================"
echo "${LOG_PREFIX} qmd wiki 검색 셋업"
echo "============================================================"
echo "  OBSIDIAN_VAULT = ${OBSIDIAN_VAULT}"
echo "  qmd            = $(command -v qmd)"
echo "  qmd version    = $(qmd --version 2>/dev/null || echo 'unknown')"
echo ""

# -----------------------------------------------------------------------------
# 컬렉션 등록 (멱등)
#
# qmd collection add 는 기존 컬렉션에 대해 비 0 exit 할 가능성이 있으므로
# `|| true` 로 흡수한다. 두 번째 이후 실행에서도 같은 최종 상태로 수렴한다.
# -----------------------------------------------------------------------------

add_collection() {
  local path="$1"
  local name="$2"

  if [[ ! -d "${path}" ]]; then
    echo "${LOG_PREFIX} [skip] ${name}: directory not found (${path})"
    return 0
  fi

  # qmd 2.1.0 은 기본값으로 `**/*.md` 패턴으로 수집하므로 --mask 는 불필요.
  if qmd collection add "${path}" --name "${name}" >/dev/null 2>&1; then
    echo "${LOG_PREFIX} [added] ${name} -> ${path}"
  else
    echo "${LOG_PREFIX} [exists] ${name} (already registered or add failed; treated as idempotent)"
  fi
}

echo "--- 컬렉션 등록 ---"
add_collection "${OBSIDIAN_VAULT}/wiki"         "brain-wiki"
add_collection "${OBSIDIAN_VAULT}/raw-sources"  "brain-sources"
if [[ "${INCLUDE_LOGS}" == "1" ]]; then
  add_collection "${OBSIDIAN_VAULT}/session-logs" "brain-logs"
else
  echo "${LOG_PREFIX} [skip] brain-logs: session-logs/ 등록은 기본값으로 비활성입니다 (--include-logs 로 활성화)"
fi

# -----------------------------------------------------------------------------
# 컨텍스트 추가 (검색 정확도 향상을 위한 컬렉션 설명)
# -----------------------------------------------------------------------------

echo ""
echo "--- 컨텍스트 추가 ---"
qmd context add qmd://brain-wiki    "LLM wiki 지식 베이스: 설계 판단, 개념, 패턴, 버그 해결책, 프로젝트 정보" >/dev/null 2>&1 || true
qmd context add qmd://brain-sources "원본 자료: 기사, 서적 메모, 트랜스크립트, 아이디어"                               >/dev/null 2>&1 || true
if [[ "${INCLUDE_LOGS}" == "1" ]]; then
  qmd context add qmd://brain-logs    "Claude Code 세션 로그: 작업 기록, 명령 이력"                              >/dev/null 2>&1 || true
fi
echo "${LOG_PREFIX} context registered (or already present)"

# -----------------------------------------------------------------------------
# 최초 인덱스 생성
# -----------------------------------------------------------------------------

echo ""
echo "--- BM25 인덱스 갱신 ---"
qmd update >/dev/null 2>&1 || echo "${LOG_PREFIX} [warn] qmd update failed (continuing)"

if [[ "${GIEOK_QMD_SKIP_EMBED:-0}" == "1" ]]; then
  echo "${LOG_PREFIX} GIEOK_QMD_SKIP_EMBED=1 -> skipping qmd embed"
else
  echo ""
  echo "--- 벡터 임베딩 생성 ---"
  echo "${LOG_PREFIX} 최초에는 GGUF 모델 다운로드에 몇 분 걸립니다..."
  qmd embed >/dev/null 2>&1 || echo "${LOG_PREFIX} [warn] qmd embed failed; run 'qmd embed' manually later"
fi

# -----------------------------------------------------------------------------
# 요약
# -----------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "${LOG_PREFIX} 셋업 완료"
echo "============================================================"
echo ""
echo "등록된 컬렉션:"
qmd collection list 2>/dev/null || echo "  (qmd collection list failed)"
echo ""
echo "다음 단계:"
echo "  1. MCP 데몬 기동: bash $(dirname "$0")/install-qmd-daemon.sh"
echo "  2. ~/.claude/settings.json 에 qmd MCP 서버 설정을 추가"
echo "     (install-qmd-daemon.sh 가 완료 시 출력하는 설정 예를 참조)"
echo "  3. 동작 확인: qmd query \"설계 판단\""
