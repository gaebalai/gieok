#!/usr/bin/env bash
#
# build-mcpb.sh — GIEOK MCP 서버를 .mcpb 번들로 패키징한다 (Phase N)
#
# 공식 CLI `@anthropic-ai/mcpb` 를 npx 를 통해 기동하여 tools/claude-brain/mcp/ 를
# Claude Desktop 용의 단일 파일 .mcpb 로 묶는다.
#
# 출력:
#   tools/claude-brain/mcp/dist/gieok-wiki-<version>.mcpb
#
# 종료 코드:
#   0  정상 종료 / DRY RUN 완료
#   1  node 부재 / 버전 부족 / npm 부재 / mcpb pack 실패
#
# 사용법:
#   bash tools/claude-brain/scripts/build-mcpb.sh             # 실제 빌드
#   bash tools/claude-brain/scripts/build-mcpb.sh --dry-run   # staging 구축까지 (pack 은 하지 않음)
#   bash tools/claude-brain/scripts/build-mcpb.sh --validate  # mcpb validate 만 수행
#   bash tools/claude-brain/scripts/build-mcpb.sh --clean     # build/ 와 dist/ 를 삭제하고 종료
#
# 참고:
#   - mcp-server-dev:build-mcpb skill (공식)
#   - manifest schema: https://raw.githubusercontent.com/anthropics/mcpb/main/schemas/mcpb-manifest-v0.4.schema.json

set -euo pipefail

DRY_RUN=0
VALIDATE_ONLY=0
CLEAN_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --validate) VALIDATE_ONLY=1 ;;
    --clean) CLEAN_ONLY=1 ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$(cd "${SCRIPT_DIR}/../mcp" && pwd)"
BUILD_DIR="${MCP_DIR}/build"
STAGING_DIR="${BUILD_DIR}/staging"
DIST_DIR="${MCP_DIR}/dist"
MANIFEST_SRC="${MCP_DIR}/manifest.json"

echo "build-mcpb: mcp dir = ${MCP_DIR}"

# -----------------------------------------------------------------------------
# --clean: build/ 와 dist/ 를 삭제하고 종료
# -----------------------------------------------------------------------------

if [[ "${CLEAN_ONLY}" -eq 1 ]]; then
  rm -rf "${BUILD_DIR}" "${DIST_DIR}"
  echo "build-mcpb: [clean] removed ${BUILD_DIR} and ${DIST_DIR}"
  exit 0
fi

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if [[ ! -f "${MANIFEST_SRC}" ]]; then
  echo "ERROR: manifest.json not found at ${MANIFEST_SRC}" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node not found in PATH (Node 18+ required)" >&2
  exit 1
fi

NODE_VERSION="$(node --version 2>/dev/null | sed 's/^v//')"
NODE_MAJOR="${NODE_VERSION%%.*}"
if [[ ! "${NODE_MAJOR}" =~ ^[0-9]+$ ]] || [[ "${NODE_MAJOR}" -lt 18 ]]; then
  echo "ERROR: Node 18+ required (found: ${NODE_VERSION})" >&2
  exit 1
fi
echo "build-mcpb: node = $(command -v node) (v${NODE_VERSION})"

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm not found in PATH" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "ERROR: npx not found in PATH" >&2
  exit 1
fi

# manifest version (jq 가 있으면 추출, 없으면 node 로 폴백)
if command -v jq >/dev/null 2>&1; then
  MANIFEST_VERSION="$(jq -r '.version' "${MANIFEST_SRC}")"
else
  MANIFEST_VERSION="$(node -p "require('${MANIFEST_SRC}').version")"
fi
echo "build-mcpb: manifest version = ${MANIFEST_VERSION}"

# -----------------------------------------------------------------------------
# --validate: manifest 만 검증하고 종료
# -----------------------------------------------------------------------------

if [[ "${VALIDATE_ONLY}" -eq 1 ]]; then
  echo "build-mcpb: [validate] running mcpb validate..."
  (cd "${MCP_DIR}" && npx --yes @anthropic-ai/mcpb validate manifest.json)
  echo "build-mcpb: [validate] OK"
  exit 0
fi

# -----------------------------------------------------------------------------
# staging 생성
# -----------------------------------------------------------------------------

echo "build-mcpb: [stage] cleaning ${STAGING_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/server"

echo "build-mcpb: [stage] copying manifest"
cp "${MANIFEST_SRC}" "${STAGING_DIR}/manifest.json"

# 동봉 대상은 server 코드와 package 메타뿐. 테스트/빌드 산출물은 넣지 않는다.
echo "build-mcpb: [stage] copying server code"
cp "${MCP_DIR}/server.mjs" "${STAGING_DIR}/server/server.mjs"
cp "${MCP_DIR}/package.json" "${STAGING_DIR}/server/package.json"
if [[ -f "${MCP_DIR}/package-lock.json" ]]; then
  cp "${MCP_DIR}/package-lock.json" "${STAGING_DIR}/server/package-lock.json"
fi
cp -R "${MCP_DIR}/lib" "${STAGING_DIR}/server/lib"
cp -R "${MCP_DIR}/tools" "${STAGING_DIR}/server/tools"

# tools/ 하위에 개발 중 생긴 쓰레기 (예: 빈 서브디렉터리 tools/claude-brain/) 가 있으면
# .mjs 파일 이외를 staging 에서 제거한다.
find "${STAGING_DIR}/server/tools" -mindepth 1 -type d -empty -delete 2>/dev/null || true

# 2026-04-20 v0.3.3 fix (기능 2.1 이후의 장기 버그): MCP tool `gieok_ingest_pdf` 는
# `scripts/extract-pdf.sh` 를 spawn 하지만 (ingest-pdf.mjs 내에서
# `join(__dirname, '..', '..', 'scripts', 'extract-pdf.sh')` 로 resolve),
# v0.2.0/v0.3.0/v0.3.1/v0.3.2 의 .mcpb bundle 에 이 shell script 가 포함되어
# 있지 않았기 때문에 Claude Desktop 을 통해 gieok_ingest_pdf 를 호출하면 rc=127 로
# 실패했다 (dev 시에는 parent repo 직접 경로로 resolve 되므로 dogfooding 으로도
# 검출되지 않았다). staging 루트에 scripts/ 를 배치함으로써
# server/tools/ingest-pdf.mjs 에서 `../../scripts/extract-pdf.sh` 가 올바르게 resolve 된다.
#
# 동봉 대상:
#   - extract-pdf.sh        : gieok_ingest_pdf 가 spawn (필수)
#   - mask-text.mjs         : extract-pdf.sh 가 Node CLI 로 호출 (필수)
#   - lib/masking.mjs       : mask-text.mjs 가 import (필수)
#   - extract-url.sh        : 향후 MCP-side 에서 spawn 할 가능성 있음 (현재는 cron 전용이나 만일을 위해)
#   - auto-ingest.sh / auto-lint.sh / setup-*.sh / install-*.sh 등의 cron/setup 계열:
#     MCP 에서 spawn 되지 않음 → 제외한다 (불필요한 배포물을 줄인다)
echo "build-mcpb: [stage] copying MCP-invoked scripts (extract-pdf.sh + deps)"
mkdir -p "${STAGING_DIR}/scripts"
cp "${SCRIPT_DIR}/extract-pdf.sh" "${STAGING_DIR}/scripts/extract-pdf.sh"
cp "${SCRIPT_DIR}/mask-text.mjs" "${STAGING_DIR}/scripts/mask-text.mjs"
cp "${SCRIPT_DIR}/extract-url.sh" "${STAGING_DIR}/scripts/extract-url.sh"
cp -R "${SCRIPT_DIR}/lib" "${STAGING_DIR}/scripts/lib"
# 실행 권한을 명시 (cp -p 는 테스트 환경의 uid 차이로 실패할 수 있으므로 chmod 로 확정)
chmod 0755 "${STAGING_DIR}/scripts/extract-pdf.sh"
chmod 0755 "${STAGING_DIR}/scripts/extract-url.sh"

# -----------------------------------------------------------------------------
# staging 에서 프로덕션 의존성을 install (lock 파일이 있으면 npm ci, 없으면 npm install)
# -----------------------------------------------------------------------------

echo "build-mcpb: [stage] installing production dependencies into staging"
if [[ -f "${STAGING_DIR}/server/package-lock.json" ]]; then
  (cd "${STAGING_DIR}/server" && npm ci --omit=dev --no-audit --no-fund --silent)
else
  (cd "${STAGING_DIR}/server" && npm install --omit=dev --no-audit --no-fund --silent)
fi

# -----------------------------------------------------------------------------
# --dry-run: pack 하지 않고 staging 만 확인
# -----------------------------------------------------------------------------

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo ""
  echo "build-mcpb: [dry-run] staging built at ${STAGING_DIR}"
  echo "build-mcpb: [dry-run] would run: npx --yes @anthropic-ai/mcpb pack"
  echo ""
  echo "staging tree (top-level):"
  find "${STAGING_DIR}" -maxdepth 2 -mindepth 1 | sort | sed 's|^|  |'
  exit 0
fi

# -----------------------------------------------------------------------------
# pack
# -----------------------------------------------------------------------------

mkdir -p "${DIST_DIR}"
OUTPUT="${DIST_DIR}/gieok-wiki-${MANIFEST_VERSION}.mcpb"

echo ""
echo "build-mcpb: [pack] generating ${OUTPUT}"
# `mcpb pack <source> <output>` 로 source 디렉터리를 zip 하고 manifest 를 검증한다
(cd "${STAGING_DIR}" && npx --yes @anthropic-ai/mcpb pack . "${OUTPUT}")

if [[ ! -f "${OUTPUT}" ]]; then
  echo "ERROR: mcpb pack succeeded but output file not found at ${OUTPUT}" >&2
  exit 1
fi

OUTPUT_SIZE="$(wc -c <"${OUTPUT}" | awk '{printf "%.1f", $1/1024/1024}')"

cat <<EOF

============================================================
완료 — GIEOK MCPB 번들을 생성했습니다
============================================================

  파일: ${OUTPUT}
  크기: ${OUTPUT_SIZE} MB

설치 (Claude Desktop):

  1. Claude Desktop 을 기동
  2. 위의 .mcpb 파일을 창에 드래그&드롭
  3. Vault directory 에 Obsidian Vault 경로를 지정 → Install
  4. 설정 > MCP 에서 gieok-wiki 가 ON 으로 되어 있는지 확인

검증만 해보고 싶다면:

  npx --yes @anthropic-ai/mcpb info "${OUTPUT}"

EOF
