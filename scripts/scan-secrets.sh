#!/usr/bin/env bash
#
# scan-secrets.sh — session-logs/ 하위의 비밀 정보 누출 감지 (open-issues #6)
#
# session-logger.mjs 의 MASK_RULES 는 유닛 테스트에서는 동작하지만, 실 세션에서
# 신종 토큰 (예: `github_pat_` 가 등장하기 전의 구 GitHub PAT `ghp_` 만
# 패턴에 있는 등) 이 혼입된 경우를 눈치채지 못한다. 본 스크립트는 session-logs/
# 하위를 이미 알려진 비밀 패턴으로 grep 하여 마스킹 누락을 감지한다.
#
# 사용 예:
#   bash tools/claude-brain/scripts/scan-secrets.sh                # 기본 Vault 스캔
#   OBSIDIAN_VAULT=/path bash scan-secrets.sh                      # 다른 Vault
#   bash scan-secrets.sh --json                                    # JSON 요약 출력 (기계 판독)
#
# 환경 변수:
#   OBSIDIAN_VAULT   Vault 루트 (미설정 시 $HOME/claude-brain/main-claude-brain)
#
# 종료 코드:
#   0  스캔 완료 (히트 유무와 무관하게 정상 종료)
#   1  Vault 가 존재하지 않음 / session-logs/ 가 존재하지 않음
#   2  마스킹 누락이 1건 이상 발견됨 (cron 에서 모니터링할 용도)
#
# cron 사용 예 (월 1회):
#   0 9 1 * * /ABS/scan-secrets.sh >> "$HOME/claude-brain-scan.log" 2>&1

set -euo pipefail

LOG_PREFIX="[scan-secrets $(date +%Y%m%d-%H%M)]"

OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-${HOME}/claude-brain/main-claude-brain}"

# NEW-001: OBSIDIAN_VAULT 유효성 검증 (JSON 폴백 시 인젝션 방지)
validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ $safe_re ]]; then
    echo "error: OBSIDIAN_VAULT contains unsafe characters: ${p}" >&2
    exit 1
  fi
}
validate_vault_path "${OBSIDIAN_VAULT}"

JSON_MODE=0
if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=1
fi

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if [[ ! -d "${OBSIDIAN_VAULT}" ]]; then
  echo "${LOG_PREFIX} ERROR: OBSIDIAN_VAULT not found: ${OBSIDIAN_VAULT}" >&2
  exit 1
fi

# 2026-04-20 HIGH-b2 fix (documentation): 스캔 대상은 session-logs/ 하위로 한정한다.
# 향후 "Vault 전체 스캔" 하도록 확장할 경우 반드시 아래를 제외할 것:
#   - .cache/html/   : 기능 2.2 가 저장하는 attacker-controlled raw HTML (injection pattern
#                      을 의도적으로 박아 두면 오탐 폭주 / DoS 유도 가능)
#   - .cache/extracted/ : PDF 추출 chunk. 마스킹 완료지만 대량 생성 노이즈 원천
#   - .obsidian/     : Obsidian 설정 (기계 생성, token 형태의 해시를 포함할 수 있음)
#   - raw-sources/<subdir>/fetched/media/ : 이미지 바이너리 (grep 에서도 오매칭의 온상)
# 어떻게 확장할지는 scripts/scan-secrets.sh 의 "Scope" 섹션에서 논의한다.
LOGS_DIR="${OBSIDIAN_VAULT}/session-logs"
if [[ ! -d "${LOGS_DIR}" ]]; then
  echo "${LOG_PREFIX} ERROR: session-logs/ not found under ${OBSIDIAN_VAULT}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 비밀 정보 패턴 정의
#
# 중요: session-logger.mjs 의 MASK_RULES 에 대응하는 패턴을 ERE 로 다시 쓴 것.
# 여기 있는 패턴에 히트되면 "마스킹 누락".
#
# 이미 `***` 로 마스킹된 문자열은 제외하기 위해, 말미에 "치환 후의 플레이스홀더가
# 아닌 것" 을 체크하는 형태는 취하지 않고, 단순히 grep 히트 건수를 센 뒤 후단에서
# 육안 확인하기 쉽도록 컨텍스트와 함께 출력한다.
# -----------------------------------------------------------------------------

# 이름과 패턴을 병렬로 보관 (bash 3.2 호환을 위해 연관 배열은 쓰지 않음).
PATTERN_NAMES=(
  "Anthropic API key (sk-ant-)"
  "OpenAI project key (sk-proj-)"
  "OpenAI-style API key (sk-)"
  "GitHub personal access token (ghp_)"
  "GitHub fine-grained PAT (github_pat_)"
  "GitHub OAuth token (gho_)"
  "GitHub user-to-server token (ghu_)"
  "Google API key (AIza)"
  "AWS access key (AKIA)"
  "Slack token (xox*-)"
  "Vercel token (vercel_)"
  "npm token (npm_)"
  "Stripe key (sk_live/pk_live/rk_live)"
  "Supabase service role key (sbp_)"
  "Firebase/GCP private_key_id"
  "Azure SharedAccessKey/AccountKey"
  "Bearer token"
  "Basic/Digest auth"
  "URL embedded credentials"
  "PEM private key"
  "key=value style secret"
)

# 주의: ERE (grep -E) 용. session-logger.mjs 의 JS regex 와 동등해지도록 조정 완료.
# - 길이 조건은 {20,} 로 통일 (session-logger 와 동일 임계값)
# - `key=value` 는 키 이름 리스트와 말미의 비공백 문자로 단순하게 매치
PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk-proj-[A-Za-z0-9_-]{20,}'
  'sk-[A-Za-z0-9]{20,}'
  'ghp_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'gho_[A-Za-z0-9]{20,}'
  'ghu_[A-Za-z0-9]{20,}'
  'AIza[A-Za-z0-9_-]{20,}'
  'AKIA[A-Z0-9]{16}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'vercel_[A-Za-z0-9_-]{20,}'
  'npm_[A-Za-z0-9]{20,}'
  '[spr]k_(live|test)_[A-Za-z0-9]{20,}'
  'sbp_[A-Za-z0-9]{20,}'
  'private_key_id['"'"'"[:space:]]*[:=][[:space:]]*['"'"'"]*[a-f0-9]{40}'
  '(SharedAccessKey|AccountKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{20,}'
  'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
  '(Basic|Digest)[[:space:]]+[A-Za-z0-9+/=]{10,}'
  '://[^:]+:[^@]+@'
  '-----BEGIN [A-Z ]+PRIVATE KEY-----'
  '(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*"?[^[:space:]"'"'"'&*]{8,}'
)

# -----------------------------------------------------------------------------
# 스캔
#
# - `*.md` 만 대상 (session-logs/.claude-brain/errors.log 등은 제외)
# - 파일명은 sanitize 완료라 개행을 포함하지 않는다는 전제
# - 각 패턴의 히트 건수를 집계하고 상세는 stderr 로 출력
# -----------------------------------------------------------------------------

TOTAL_HITS=0
HIT_DETAIL=""  # "pattern_name<TAB>count" 를 개행으로 구분해 누적

for i in "${!PATTERNS[@]}"; do
  pat="${PATTERNS[$i]}"
  name="${PATTERN_NAMES[$i]}"

  # grep -r 는 session-logs/ 하위를 재귀 스캔.
  # --include='*.md' 로 대상 한정.
  # -E 로 ERE, -I 로 바이너리 제외, -c 는 히트 행 수가 아니라 파일별 건수이므로 쓰지 않고
  # 명시적으로 행 수를 센다.
  # grep 은 매치 0건일 때 exit 1 을 반환하므로 `|| true` 로 파이프 실패를 흡수한다
  # (set -o pipefail 하에서도 count=0 을 얻기 위해).
  count=$({ grep -rEIho --include='*.md' -- "${pat}" "${LOGS_DIR}" 2>/dev/null || true; } | wc -l | tr -d ' ')
  count="${count:-0}"

  if [[ "${count}" -gt 0 ]]; then
    TOTAL_HITS=$((TOTAL_HITS + count))
    HIT_DETAIL+="${name}	${count}"$'\n'
  fi
done

# -----------------------------------------------------------------------------
# 출력
# -----------------------------------------------------------------------------

if [[ "${JSON_MODE}" == "1" ]]; then
  # VULN-007: jq 로 구조적으로 JSON 을 생성 (경로 문자열 이스케이프 누락 방지)
  if command -v jq >/dev/null 2>&1; then
    jq -n --argjson hits "${TOTAL_HITS}" --arg vault "${OBSIDIAN_VAULT}" --arg scanned "${LOGS_DIR}" \
      '{total_hits: $hits, vault: $vault, scanned: $scanned}'
  else
    # jq 부재 시 폴백 (경로에 제어 문자가 없다는 전제)
    printf '{"total_hits":%d,"vault":"%s","scanned":"%s"}\n' \
      "${TOTAL_HITS}" "${OBSIDIAN_VAULT}" "${LOGS_DIR}"
  fi
else
  echo "${LOG_PREFIX} Scanning ${LOGS_DIR} ..."
  if [[ "${TOTAL_HITS}" == "0" ]]; then
    echo "${LOG_PREFIX} OK: no secret-like patterns found."
  else
    echo "${LOG_PREFIX} WARNING: ${TOTAL_HITS} potential secret leak(s) detected:"
    # HIT_DETAIL 은 name<TAB>count 행들
    printf '%s' "${HIT_DETAIL}" | while IFS=$'\t' read -r name count; do
      [[ -z "${name}" ]] && continue
      printf '  - %-40s %s hit(s)\n' "${name}" "${count}"
    done
    echo "${LOG_PREFIX} Review session-logs/ manually. Matching files:"
    # 매칭된 파일을 열거 (중복 제거). 히트한 패턴 중 하나라도 포함한 파일.
    {
      for pat in "${PATTERNS[@]}"; do
        grep -rEIl --include='*.md' -- "${pat}" "${LOGS_DIR}" 2>/dev/null || true
      done
    } | sort -u | sed 's/^/    /'
    echo "${LOG_PREFIX} If these are false positives, add the pattern to an allowlist."
    echo "${LOG_PREFIX} If they are real leaks, extend MASK_RULES in hooks/session-logger.mjs."
  fi
fi

# 누락이 있는 경우 exit 2 (cron 에서 감지할 용도)
if [[ "${TOTAL_HITS}" -gt 0 ]]; then
  exit 2
fi
exit 0
