#!/usr/bin/env bash
#
# post-release-sync.sh — parent의 app/ snapshot을 gieok main의 최신 state와 맞춘다
#
# 배경 (2026-04-21 v0.4.0 release 시점에 표면화됨):
#   sync-to-app.sh는 gieok `next`에 push한다. 그 끝에서 `git checkout main
#   && git merge --ff-only origin/main`이 실행되지만, 이는 push 직후 타이밍이라
#   gieok PR #N이 main에 merge되기 **전**이다. 따라서 sync-to-app 종료 시점의
#   app/은 "한 세대 뒤처진 gieok main snapshot" 이 된다 (= parent HEAD와
#   일치하지 않아 다음 parent commit에서 의도치 않은 diff가 발생).
#
#   이 script는 gieok `next → main` PR을 merge한 **후** 에 별도로 호출하여
#   app/을 gieok 최신 main state에 맞춘다. --commit 을 주면 parent 쪽 commit + push
#   까지 자동화할 수 있다.
#
# Usage:
#   bash tools/claude-brain/scripts/post-release-sync.sh             # 동기화만 (수동 commit)
#   bash tools/claude-brain/scripts/post-release-sync.sh --commit    # 동기화 + parent commit + push
#   bash tools/claude-brain/scripts/post-release-sync.sh --dry-run   # 실행 예정만 표시
#   bash tools/claude-brain/scripts/post-release-sync.sh --help      # usage
#
# 전제:
#   - app/.git-gieok 이 존재 (gieok repo의 .git)
#   - origin remote가 megaphone-tokyo/gieok 을 가리킴 (sync-to-app과 동일)
#
# 호환성: sync-to-app.sh의 동작은 일절 변경하지 않는다. 본 script는 추가적인 post-hook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRAIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${BRAIN_DIR}/app"
REPO_ROOT="$(cd "${BRAIN_DIR}/../.." && pwd)"

MODE=sync
for arg in "$@"; do
  case "${arg}" in
    --commit) MODE=commit ;;
    --dry-run) MODE=dry-run ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# 전제 check
# -----------------------------------------------------------------------------

if [[ ! -d "${APP_DIR}/.git-gieok" ]]; then
  echo "ERROR: ${APP_DIR}/.git-gieok not found. Is gieok repo initialized?" >&2
  exit 1
fi

cd "${APP_DIR}"

# Crash recovery guard (sync-to-app.sh MED-f1 pattern):
# .git과 .git-gieok이 둘 다 남아 있으면 다음 mv가 파괴적이므로 abort.
if [[ -d .git && -d .git-gieok ]]; then
  echo "ERROR: app/.git and app/.git-gieok both exist." >&2
  echo "  This is a leftover from a crashed sync-to-app or post-release-sync run." >&2
  echo "  Manual recovery required: 'rm -rf $(pwd)/.git' (re-clone gieok if needed)." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# --dry-run: 실행 예정만 표시하고 exit
# -----------------------------------------------------------------------------

if [[ "${MODE}" == "dry-run" ]]; then
  echo "=== post-release-sync: dry-run (no side effects) ==="
  echo "  would: mv .git-gieok .git"
  echo "  would: git fetch origin --quiet"
  echo "  would: git checkout main --quiet"
  echo "  would: git merge --ff-only origin/main --quiet"
  echo "  would: mv .git .git-gieok"
  echo "  would: cd \"${REPO_ROOT}\" && git status --short tools/claude-brain/app/"
  echo "  would: (if --commit) git add / commit / push origin main"
  exit 0
fi

# -----------------------------------------------------------------------------
# gieok main의 최신 state에 app/을 맞춘다
# -----------------------------------------------------------------------------

# trap을 먼저 설치한 뒤 rename (실패 시에도 .git → .git-gieok 으로 복원)
trap 'cd "${APP_DIR}" && [[ -d .git ]] && mv .git .git-gieok 2>/dev/null || true' EXIT INT TERM HUP
mv .git-gieok .git

echo "=== post-release-sync: fetching + aligning app/ to gieok main ==="
git fetch origin --quiet
git checkout main --quiet
git merge --ff-only origin/main --quiet
GIEOK_MAIN_SHA="$(git rev-parse HEAD)"

mv .git .git-gieok
# trap은 .git 부재 시 noop 이므로 안전

cd "${REPO_ROOT}"

echo ""
echo "  app/ now aligned to gieok main: ${GIEOK_MAIN_SHA:0:7}"
echo ""

# -----------------------------------------------------------------------------
# parent 관점의 diff 표시
# -----------------------------------------------------------------------------

echo "=== parent repo diff for tools/claude-brain/app/ ==="
parent_diff="$(git status --short tools/claude-brain/app/ 2>/dev/null)"
if [[ -z "${parent_diff}" ]]; then
  echo "  (no diff — parent app/ snapshot already matches gieok main)"
  echo ""
  echo "=== done ==="
  exit 0
fi
printf '%s\n' "${parent_diff}" | head -20
echo ""

# -----------------------------------------------------------------------------
# --commit mode: parent에 auto commit + push
# -----------------------------------------------------------------------------

if [[ "${MODE}" == "commit" ]]; then
  echo "=== committing + pushing ==="
  git add tools/claude-brain/app/
  git commit -m "claude-brain: post-release app/ snapshot sync (gieok main ${GIEOK_MAIN_SHA:0:7})"
  git push origin main
  echo "=== done (committed + pushed) ==="
else
  echo "Next steps (run manually, or re-invoke with --commit):"
  echo "  git add tools/claude-brain/app/"
  echo "  git commit -m 'claude-brain: post-release app/ snapshot sync (gieok main ${GIEOK_MAIN_SHA:0:7})'"
  echo "  git push origin main"
fi
