#!/usr/bin/env bash
#
# cron-guard-parity.test.sh — cron/setup 계층의 env-override 가드 통일성을
# invariant 테스트로 강제한다 (v0.4.0 Tier B#2).
#
# 실행: bash tools/claude-brain/tests/cron-guard-parity.test.sh
#
# ## 배경
#
# claude-brain에는 2가지 계열의 env override / escape-hatch flag가 존재한다:
#
# 1. **Category A — script override gate** (v0.3.0 VULN-004 대책):
#    `GIEOK_EXTRACT_<RES>_SCRIPT` / `GIEOK_ALLOW_EXTRACT_<RES>_OVERRIDE` 쌍으로,
#    테스트 시에만 script path를 교체하기 위한 env. production cron에서는
#    _OVERRIDE gate가 없으면 WARN + 무시한다. 사용처는 scripts/auto-ingest.sh 뿐.
#
# 2. **Category B — cron escape hatch** (v0.3.0 LOW-d4 + v0.3.1 NEW-L2 대책):
#    `GIEOK_ALLOW_<HAZARD>_IN_CRON` 으로 cron 경로에서 위험 조작 (loopback / robots bypass)
#    을 명시적으로 opt-in 하는 gate. 사용처는 scripts/extract-url.sh 뿐.
#
# 둘 다 child-env.mjs의 ENV_ALLOW_EXACT allowlist에는 **의도적으로 올리지 않는다**
# (HIGH-d1 fix + NEW-L2 의 설계 의도). 본 테스트는 이 설계 의도가 drift 하지 않도록
# 불변 조건을 enforce 한다.
#
# ## 검증 항목
#
#   CGP-1 auto-ingest.sh의 각 GIEOK_EXTRACT_<X>_SCRIPT에 대응하는
#         GIEOK_ALLOW_EXTRACT_<X>_OVERRIDE ignore 분기가 존재 (A pattern 의 대칭성)
#   CGP-2 mcp/lib/child-env.mjs의 ENV_ALLOW_EXACT 에 GIEOK_EXTRACT_* /
#         GIEOK_ALLOW_EXTRACT_* / GIEOK_URL_* / GIEOK_ALLOW_*_IN_CRON 이 실려 있지 않음
#   CGP-3 scripts/extract-url.sh 에 Category B escape hatch 가드
#         (GIEOK_ALLOW_LOOPBACK_IN_CRON / GIEOK_ALLOW_IGNORE_ROBOTS_IN_CRON) 존재
#   CGP-4 Category A pattern (GIEOK_EXTRACT_*_SCRIPT) 을 사용하는 것은 scripts/auto-ingest.sh
#         뿐 (다른 script 로의 drift 없음)
#   CGP-5 Category B pattern (GIEOK_ALLOW_*_IN_CRON) 을 사용하는 것은 scripts/extract-url.sh
#         뿐 (다른 script 로의 drift 없음)
#
# 주의: macOS 표준 bash 3.2 에서도 동작하도록 `mapfile` / associative array /
# process substitution 의 다용을 피하고 있다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TOOL_ROOT="${REPO_ROOT}/tools/claude-brain"
SCRIPTS_DIR="${TOOL_ROOT}/scripts"
CHILD_ENV="${TOOL_ROOT}/mcp/lib/child-env.mjs"
AUTO_INGEST="${SCRIPTS_DIR}/auto-ingest.sh"
EXTRACT_URL="${SCRIPTS_DIR}/extract-url.sh"

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
# CGP-1: Category A pattern의 대칭성
#   각 GIEOK_EXTRACT_<X>_SCRIPT에 대해, 동일한 <X> 의 GIEOK_ALLOW_EXTRACT_<X>_OVERRIDE
#   ignore 분기 (WARN + fallback) 가 존재하는지 확인.
# -----------------------------------------------------------------------------
echo "test CGP-1: auto-ingest.sh의 script override 게이트 대칭성"

if [[ ! -f "${AUTO_INGEST}" ]]; then
  fail "CGP-1 auto-ingest.sh not found at ${AUTO_INGEST}"
else
  # GIEOK_EXTRACT_<X>_SCRIPT 를 env lookup 하는 행에서 <X> 를 추출
  extract_resources="$(
    grep -oE 'GIEOK_EXTRACT_[A-Z]+_SCRIPT' "${AUTO_INGEST}" 2>/dev/null \
      | sed -E 's/^GIEOK_EXTRACT_([A-Z]+)_SCRIPT$/\1/' \
      | sort -u \
      | tr '\n' ' '
  )"

  if [[ -z "${extract_resources// }" ]]; then
    fail "CGP-1 no GIEOK_EXTRACT_*_SCRIPT lookup found in auto-ingest.sh (regression?)"
  else
    pass "CGP-1 found script-override resource(s): ${extract_resources}"
  fi

  # 각 <X> 에 대해, 대응하는 _SCRIPT lookup / _OVERRIDE gate / WARN 이 존재하는지
  for res in ${extract_resources}; do
    script_re="\\\$\\{GIEOK_EXTRACT_${res}_SCRIPT:-"
    override_re="\\\$\\{GIEOK_ALLOW_EXTRACT_${res}_OVERRIDE:-0\\}"
    warn_str="GIEOK_EXTRACT_${res}_SCRIPT is set but GIEOK_ALLOW_EXTRACT_${res}_OVERRIDE"

    if grep -qE "${script_re}" "${AUTO_INGEST}"; then
      pass "CGP-1[${res}] script env lookup present"
    else
      fail "CGP-1[${res}] script env lookup \${GIEOK_EXTRACT_${res}_SCRIPT:-...} not found"
    fi

    if grep -qE "${override_re}" "${AUTO_INGEST}"; then
      pass "CGP-1[${res}] override gate present"
    else
      fail "CGP-1[${res}] gate \${GIEOK_ALLOW_EXTRACT_${res}_OVERRIDE:-0} not found"
    fi

    if grep -qF "${warn_str}" "${AUTO_INGEST}"; then
      pass "CGP-1[${res}] WARN message present"
    else
      fail "CGP-1[${res}] WARN message naming both flags not found"
    fi
  done

  # 역방향: GIEOK_ALLOW_EXTRACT_<X>_OVERRIDE 에 대응하는 _SCRIPT 도 필수
  override_resources="$(
    grep -oE 'GIEOK_ALLOW_EXTRACT_[A-Z]+_OVERRIDE' "${AUTO_INGEST}" 2>/dev/null \
      | sed -E 's/^GIEOK_ALLOW_EXTRACT_([A-Z]+)_OVERRIDE$/\1/' \
      | sort -u \
      | tr '\n' ' '
  )"
  for res in ${override_resources}; do
    # extract_resources에 포함되는지 (공백 구분으로 포함 체크)
    if printf ' %s ' "${extract_resources}" | grep -qF " ${res} "; then
      pass "CGP-1[${res}] _OVERRIDE has matching _SCRIPT (inverse check)"
    else
      fail "CGP-1[${res}] _OVERRIDE gate found but matching _SCRIPT lookup missing"
    fi
  done
fi

# -----------------------------------------------------------------------------
# CGP-2: child-env.mjs ENV_ALLOW_EXACT 에 위 flag 가 실려있지 않음 (HIGH-d1 불변)
# -----------------------------------------------------------------------------
echo "test CGP-2: child-env.mjs ENV_ALLOW_EXACT 에 금지 prefix 가 포함되지 않음"

if [[ ! -f "${CHILD_ENV}" ]]; then
  fail "CGP-2 child-env.mjs not found at ${CHILD_ENV}"
else
  # ENV_ALLOW_EXACT = new Set([ ... ]) 의 내용을 awk 로 추출
  exact_block="$(awk '/ENV_ALLOW_EXACT = new Set\(\[/,/\]\);/' "${CHILD_ENV}")"
  if [[ -z "${exact_block}" ]]; then
    fail "CGP-2 ENV_ALLOW_EXACT literal block not found"
  else
    any_leak=0
    # Category A prefixes (leaked = regression)
    for prefix in 'GIEOK_EXTRACT_' 'GIEOK_ALLOW_EXTRACT_' 'GIEOK_URL_'; do
      if printf '%s' "${exact_block}" | grep -qE "['\"]${prefix}[A-Z_]+['\"]"; then
        fail "CGP-2 forbidden prefix '${prefix}*' leaked into ENV_ALLOW_EXACT"
        any_leak=1
      fi
    done
    # Category B exact names (leaked = regression)
    for exact_name in 'GIEOK_ALLOW_LOOPBACK_IN_CRON' 'GIEOK_ALLOW_IGNORE_ROBOTS_IN_CRON'; do
      if printf '%s' "${exact_block}" | grep -qE "['\"]${exact_name}['\"]"; then
        fail "CGP-2 forbidden name '${exact_name}' leaked into ENV_ALLOW_EXACT"
        any_leak=1
      fi
    done
    if [[ "${any_leak}" -eq 0 ]]; then
      pass "CGP-2 ENV_ALLOW_EXACT excludes all forbidden patterns (Categories A + B)"
    fi
  fi

  # ENV_ALLOW_PREFIXES에 GIEOK_ 전체가 들어있지 않은지 (구 HIGH-d1 regression 방지)
  # 주석 안의 prose 기술에 오매치하지 않도록, `export const` 행으로 한정한다.
  prefixes_line="$(grep -E '^export const ENV_ALLOW_PREFIXES' "${CHILD_ENV}" || true)"
  if [[ -z "${prefixes_line}" ]]; then
    fail "CGP-2 ENV_ALLOW_PREFIXES export declaration not found"
  elif printf '%s' "${prefixes_line}" | grep -qE "['\"]GIEOK_['\"]"; then
    fail "CGP-2 ENV_ALLOW_PREFIXES contains bare 'GIEOK_' (HIGH-d1 regression)"
  else
    pass "CGP-2 ENV_ALLOW_PREFIXES excludes bare 'GIEOK_'"
  fi
fi

# -----------------------------------------------------------------------------
# CGP-3: extract-url.sh의 Category B escape hatch 가드
# -----------------------------------------------------------------------------
echo "test CGP-3: extract-url.sh의 cron escape-hatch 가드"

if [[ ! -f "${EXTRACT_URL}" ]]; then
  fail "CGP-3 extract-url.sh not found at ${EXTRACT_URL}"
else
  # Category B의 2쌍: "gate:unset_target"
  for pair in \
      'GIEOK_ALLOW_LOOPBACK_IN_CRON:GIEOK_URL_ALLOW_LOOPBACK' \
      'GIEOK_ALLOW_IGNORE_ROBOTS_IN_CRON:GIEOK_URL_IGNORE_ROBOTS'; do
    gate="${pair%%:*}"
    target="${pair##*:}"
    if grep -qE "\\\$\\{${gate}:-0\\}" "${EXTRACT_URL}"; then
      pass "CGP-3[${gate}] opt-in gate present"
    else
      fail "CGP-3[${gate}] opt-in gate not found"
    fi
    if grep -qE "unset ${target}" "${EXTRACT_URL}"; then
      pass "CGP-3[${gate}] unset ${target} line present"
    else
      fail "CGP-3[${gate}] 'unset ${target}' line not found"
    fi
  done
fi

# -----------------------------------------------------------------------------
# CGP-4: Category A pattern (GIEOK_EXTRACT_*_SCRIPT) 사용을 auto-ingest.sh 로 한정
# -----------------------------------------------------------------------------
echo "test CGP-4: Category A pattern의 사용 범위"

set +e
cat_a_users="$(grep -lE 'GIEOK_EXTRACT_[A-Z]+_SCRIPT' "${SCRIPTS_DIR}"/*.sh 2>/dev/null | sort -u | tr '\n' ' ')"
set -e

if [[ -z "${cat_a_users// }" ]]; then
  fail "CGP-4 no Category A user found (regression?)"
else
  # 기대: auto-ingest.sh 1개 파일만 (끝에 공백 붙여 비교)
  if [[ "${cat_a_users}" == "${AUTO_INGEST} " ]]; then
    pass "CGP-4 Category A usage limited to scripts/auto-ingest.sh"
  else
    fail "CGP-4 Category A pattern leaked: ${cat_a_users}"
  fi
fi

# -----------------------------------------------------------------------------
# CGP-5: Category B pattern (GIEOK_ALLOW_*_IN_CRON) 사용을 extract-url.sh 로 한정
# -----------------------------------------------------------------------------
echo "test CGP-5: Category B pattern의 사용 범위"

set +e
cat_b_users="$(grep -lE 'GIEOK_ALLOW_[A-Z_]+_IN_CRON' "${SCRIPTS_DIR}"/*.sh 2>/dev/null | sort -u | tr '\n' ' ')"
set -e

if [[ -z "${cat_b_users// }" ]]; then
  fail "CGP-5 no Category B user found (regression?)"
else
  if [[ "${cat_b_users}" == "${EXTRACT_URL} " ]]; then
    pass "CGP-5 Category B usage limited to scripts/extract-url.sh"
  else
    fail "CGP-5 Category B pattern leaked: ${cat_b_users}"
  fi
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
