#!/usr/bin/env bash
#
# install-cron.sh — claude-brain 용 cron 엔트리를 출력한다 (Phase F + G)
#
# install-hooks.sh 와 마찬가지로, 수동으로 머지해야 할 설정을 stdout 에 낸다.
# crontab 자체는 덮어쓰지 않는다 (비파괴).
#
# 사용법:
#   bash tools/claude-brain/scripts/install-cron.sh
#
# 출력된 줄을 `crontab -e` 로 수동 추가한다.

set -euo pipefail

# R4-001: OBSIDIAN_VAULT 유효성 검증
validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ $safe_re ]]; then
    echo "ERROR: OBSIDIAN_VAULT contains unsafe characters: ${p}" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTO_INGEST_ABS="${SCRIPT_DIR}/auto-ingest.sh"
AUTO_LINT_ABS="${SCRIPT_DIR}/auto-lint.sh"

if [[ ! -f "${AUTO_INGEST_ABS}" ]]; then
  echo "ERROR: auto-ingest.sh not found at ${AUTO_INGEST_ABS}" >&2
  exit 1
fi

if [[ ! -f "${AUTO_LINT_ABS}" ]]; then
  echo "ERROR: auto-lint.sh not found at ${AUTO_LINT_ABS}" >&2
  exit 1
fi

VAULT_DEFAULT="${OBSIDIAN_VAULT:-${HOME}/claude-brain/main-claude-brain}"
validate_vault_path "${VAULT_DEFAULT}"

cat <<EOF
============================================================
claude-brain 자동화 — cron 설정
============================================================

아래 명령으로 crontab 을 편집하세요:

  crontab -e

아래 줄을 추가 (경로는 이미 절대 경로로 전개되어 있습니다):

  # claude-brain: 매일 아침 7시에 자동 인제스트
  0 7 * * * ${AUTO_INGEST_ABS} >> "\$HOME/gieok-ingest.log" 2>&1

  # claude-brain: 매월 1일 아침 8시에 자동 린트
  0 8 1 * * ${AUTO_LINT_ABS} >> "\$HOME/gieok-lint.log" 2>&1

============================================================
사전 확인
============================================================

1. claude -p 가 동작하는지 확인:
     claude -p "hello" --output-format json

2. OBSIDIAN_VAULT 의 기본값:
     ${VAULT_DEFAULT}
   다른 경우 cron 줄 앞에 지정해 주세요:
     0 7 * * * OBSIDIAN_VAULT="/path/to/vault" ${AUTO_INGEST_ABS} >> ...

3. DRY RUN 으로 동작 확인:
     GIEOK_DRY_RUN=1 ${AUTO_INGEST_ABS}
     GIEOK_DRY_RUN=1 ${AUTO_LINT_ABS}

============================================================
2대 운용 시 경합 회피
============================================================

Mac mini 등 두 번째 기기에서 cron 을 설정하는 경우, git 충돌을 피하기 위해
실행 시각을 비껴 두세요. 권장:

  MacBook  — 인제스트 7:00 / 린트 매월 1일 8:00
  Mac mini — 인제스트 7:30 / 린트 매월 2일 8:00

============================================================
린트 리포트 확인 방법
============================================================

자동 린트는 수정을 수행하지 않습니다. 리포트만 생성합니다.
Obsidian 에서 wiki/lint-report.md 를 열어 내용을 확인하고,
수정이 필요한 항목은 수동으로 대응해 주세요.

============================================================
EOF
