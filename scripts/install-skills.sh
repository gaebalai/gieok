#!/usr/bin/env bash
#
# install-skills.sh — claude-brain 의 스킬을 ~/.claude/skills/ 에 symlink 로 배치한다
#
# Usage:
#   bash install-skills.sh          # 멱등적으로 symlink 를 생성
#   bash install-skills.sh --force  # 기존의 비 symlink 엔트리를 덮어쓰기
#   bash install-skills.sh --dry-run # 실제로 쓰지 않고 예정만 표시
#
# 환경 변수:
#   CLAUDE_SKILLS_DIR — 설치 대상 (기본: $HOME/.claude/skills)
#                       테스트 시 mktemp 대상으로 교체하기 위해 사용
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC_DIR="$(cd "${SCRIPT_DIR}/../skills" && pwd)"
SKILLS_DEST_DIR="${CLAUDE_SKILLS_DIR:-${HOME}/.claude/skills}"

FORCE=0
DRY_RUN=0

for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

# 대상 스킬 목록을 SKILLS_SRC_DIR 에서 자동 수집
if [[ ! -d "${SKILLS_SRC_DIR}" ]]; then
  echo "ERROR: skills source directory not found: ${SKILLS_SRC_DIR}" >&2
  exit 1
fi

SKILL_NAMES=()
for dir in "${SKILLS_SRC_DIR}"/*/; do
  [[ -d "${dir}" ]] || continue
  name="$(basename "${dir}")"
  # SKILL.md 를 가진 디렉터리만 대상으로 한다
  if [[ -f "${dir}SKILL.md" ]]; then
    SKILL_NAMES+=("${name}")
  fi
done

if [[ ${#SKILL_NAMES[@]} -eq 0 ]]; then
  echo "ERROR: no skills with SKILL.md found in ${SKILLS_SRC_DIR}" >&2
  exit 1
fi

echo "install-skills: source = ${SKILLS_SRC_DIR}"
echo "install-skills: dest   = ${SKILLS_DEST_DIR}"
echo "install-skills: skills = ${SKILL_NAMES[*]}"
echo

# 대상 디렉터리 생성
if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "DRY RUN: would mkdir -p ${SKILLS_DEST_DIR}"
else
  mkdir -p "${SKILLS_DEST_DIR}"
fi

CREATED=0
SKIPPED=0
REPLACED=0
WARNED=0

for name in "${SKILL_NAMES[@]}"; do
  src="${SKILLS_SRC_DIR}/${name}"
  dest="${SKILLS_DEST_DIR}/${name}"

  if [[ -L "${dest}" ]]; then
    current_target="$(readlink "${dest}")"
    if [[ "${current_target}" == "${src}" ]]; then
      echo "  [skip]    ${name} (already linked)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    echo "  [relink]  ${name} (was -> ${current_target})"
    if [[ ${DRY_RUN} -eq 0 ]]; then
      rm "${dest}"
      ln -s "${src}" "${dest}"
    fi
    REPLACED=$((REPLACED + 1))
    continue
  fi

  if [[ -e "${dest}" ]]; then
    if [[ ${FORCE} -eq 1 ]]; then
      echo "  [force]   ${name} (overwriting existing file/directory)"
      if [[ ${DRY_RUN} -eq 0 ]]; then
        rm -rf "${dest}"
        ln -s "${src}" "${dest}"
      fi
      REPLACED=$((REPLACED + 1))
    else
      echo "  [WARN]    ${name} exists and is not a symlink; use --force to overwrite" >&2
      WARNED=$((WARNED + 1))
    fi
    continue
  fi

  echo "  [create]  ${name}"
  if [[ ${DRY_RUN} -eq 0 ]]; then
    ln -s "${src}" "${dest}"
  fi
  CREATED=$((CREATED + 1))
done

echo
echo "install-skills: created=${CREATED} replaced=${REPLACED} skipped=${SKIPPED} warned=${WARNED}"

if [[ ${WARNED} -gt 0 ]]; then
  exit 2
fi
