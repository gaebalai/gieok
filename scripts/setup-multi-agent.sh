#!/usr/bin/env bash
#
# setup-multi-agent.sh — Gieok 의 skills/ 를 Claude Code 이외의 AI 에이전트에도 symlink 로 배포
#
# Claude Code 용으로는 `install-skills.sh` ($HOME/.claude/skills/ 하위에 per-skill symlink) 를 사용.
# 본 script 는 **그 외 에이전트** (Codex CLI / OpenCode / Gemini CLI) 를 대상으로
# `skills/` 디렉터리 전체를 `<agent-root>/skills/gieok/` 로 symlink 한다.
#
# 에이전트의 slash command / skill 인식 경로:
#   Codex CLI        : ~/.codex/skills/gieok               (참조: https://developers.openai.com/codex/skills)
#   OpenCode         : ~/.config/opencode/skills/gieok     (참조: https://opencode.ai/docs/skills/)
#   Gemini CLI       : ~/.gemini/skills/gieok              (참조: https://geminicli.com/docs/cli/skills/)
#
# 사용법:
#   bash setup-multi-agent.sh                    # 멱등하게 모든 에이전트에 symlink
#   bash setup-multi-agent.sh --agent codex      # 특정 에이전트만
#   bash setup-multi-agent.sh --dry-run          # 실행 예정만 표시, 기록 없음
#   bash setup-multi-agent.sh --uninstall        # 모든 에이전트의 symlink 를 제거
#
# 종료 코드:
#   0  정상 종료 (모든 에이전트 처리 완료, warned 포함)
#   1  치명적 오류 (skills/ 없음, unknown argument 등)
#
# 환경 변수 (테스트 override):
#   GIEOK_CODEX_SKILLS_DIR    — default: $HOME/.codex/skills
#   GIEOK_OPENCODE_SKILLS_DIR — default: $HOME/.config/opencode/skills
#   GIEOK_GEMINI_SKILLS_DIR   — default: $HOME/.gemini/skills

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC_DIR="$(cd "${SCRIPT_DIR}/../skills" && pwd)"

# 대상 에이전트 정의 (name|default_dir 배열)
# 새 에이전트 추가 시 여기를 확장
AGENTS=(
  "codex|${GIEOK_CODEX_SKILLS_DIR:-${HOME}/.codex/skills}"
  "opencode|${GIEOK_OPENCODE_SKILLS_DIR:-${HOME}/.config/opencode/skills}"
  "gemini|${GIEOK_GEMINI_SKILLS_DIR:-${HOME}/.gemini/skills}"
)

DRY_RUN=0
UNINSTALL=0
TARGET_AGENT=""

for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --agent=*) TARGET_AGENT="${arg#--agent=}" ;;
    --agent)
      echo "ERROR: --agent requires a value (e.g. --agent=codex)" >&2
      exit 1
      ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "${SKILLS_SRC_DIR}" ]]; then
  echo "ERROR: skills source directory not found: ${SKILLS_SRC_DIR}" >&2
  exit 1
fi

# symlink 이름 = gieok (고정)
LINK_NAME="gieok"

echo "setup-multi-agent: source = ${SKILLS_SRC_DIR}"
echo "setup-multi-agent: link name = ${LINK_NAME}"
if [[ -n "${TARGET_AGENT}" ]]; then
  echo "setup-multi-agent: target agent = ${TARGET_AGENT}"
fi
if [[ ${UNINSTALL} -eq 1 ]]; then
  echo "setup-multi-agent: mode = UNINSTALL"
elif [[ ${DRY_RUN} -eq 1 ]]; then
  echo "setup-multi-agent: mode = DRY RUN"
fi
echo

CREATED=0
SKIPPED=0
REPLACED=0
REMOVED=0
WARNED=0

for entry in "${AGENTS[@]}"; do
  agent_name="${entry%%|*}"
  dest_dir="${entry#*|}"
  dest_link="${dest_dir}/${LINK_NAME}"

  # --agent 필터
  if [[ -n "${TARGET_AGENT}" && "${TARGET_AGENT}" != "${agent_name}" ]]; then
    continue
  fi

  # UNINSTALL 모드
  if [[ ${UNINSTALL} -eq 1 ]]; then
    if [[ -L "${dest_link}" ]]; then
      current_target="$(readlink "${dest_link}")"
      if [[ "${current_target}" == "${SKILLS_SRC_DIR}" ]]; then
        echo "  [remove]  ${agent_name}: ${dest_link}"
        if [[ ${DRY_RUN} -eq 0 ]]; then
          rm "${dest_link}"
        fi
        REMOVED=$((REMOVED + 1))
      else
        echo "  [skip]    ${agent_name}: symlink points elsewhere (${current_target}), not touching" >&2
        WARNED=$((WARNED + 1))
      fi
    else
      echo "  [skip]    ${agent_name}: no symlink at ${dest_link}"
      SKIPPED=$((SKIPPED + 1))
    fi
    continue
  fi

  # INSTALL 모드
  # 대상 디렉터리의 부모 생성
  if [[ ${DRY_RUN} -eq 0 ]]; then
    mkdir -p "${dest_dir}"
  fi

  if [[ -L "${dest_link}" ]]; then
    current_target="$(readlink "${dest_link}")"
    if [[ "${current_target}" == "${SKILLS_SRC_DIR}" ]]; then
      echo "  [skip]    ${agent_name}: already linked (${dest_link})"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    echo "  [WARN]    ${agent_name}: symlink exists but points elsewhere (${current_target}), skipping" >&2
    echo "            remove manually to relink: rm '${dest_link}'" >&2
    WARNED=$((WARNED + 1))
    continue
  fi

  if [[ -e "${dest_link}" ]]; then
    echo "  [WARN]    ${agent_name}: ${dest_link} exists and is not a symlink, skipping" >&2
    WARNED=$((WARNED + 1))
    continue
  fi

  echo "  [create]  ${agent_name}: ${dest_link} -> ${SKILLS_SRC_DIR}"
  if [[ ${DRY_RUN} -eq 0 ]]; then
    ln -s "${SKILLS_SRC_DIR}" "${dest_link}"
  fi
  CREATED=$((CREATED + 1))
done

echo
if [[ ${UNINSTALL} -eq 1 ]]; then
  echo "setup-multi-agent: removed=${REMOVED} skipped=${SKIPPED} warned=${WARNED}"
else
  echo "setup-multi-agent: created=${CREATED} replaced=${REPLACED} skipped=${SKIPPED} warned=${WARNED}"
fi

# verify 가이드
if [[ ${UNINSTALL} -eq 0 && ${DRY_RUN} -eq 0 && ${CREATED} -gt 0 ]]; then
  echo
  echo "다음 verify 단계:"
  echo "  - Codex CLI:  codex --list-skills 2>/dev/null | grep -i gieok"
  echo "  - Gemini CLI: gemini --list-skills 2>/dev/null | grep -i gieok"
  echo "  - OpenCode:   ls ~/.config/opencode/skills/gieok/"
fi
