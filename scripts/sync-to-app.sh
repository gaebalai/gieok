#!/usr/bin/env bash
#
# sync-to-app.sh — 부모 레포의 변경을 app/ (gieok 공개 레포) 로 동기화한다
#
# 부모 레포의 hooks/, scripts/, templates/, skills/, tests/, SECURITY*.md, LICENSE 를
# app/ 에 복사하고 gieok 레포의 next 브랜치에 커밋·push 한다.
# main 에 반영하는 것은 수동으로 PR 또는 머지를 수행한다.
#
# Usage:
#   bash tools/claude-brain/scripts/sync-to-app.sh           # 동기화 + commit + push
#   bash tools/claude-brain/scripts/sync-to-app.sh --dry-run  # 차분 확인만
#
# 전제:
#   - app/.git-gieok 가 존재할 것 (gieok 레포의 .git)
#   - gieok 레포에 next 브랜치가 존재할 것 (최초에는 자동 생성)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRAIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${BRAIN_DIR}/app"
REPO_ROOT="$(cd "${BRAIN_DIR}/../.." && pwd)"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

# -----------------------------------------------------------------------------
# GitHub-side lock (α): 2026-04-21 NEW-L2 fix (v0.4.0 Tier B#3)
#
# 2대 운용 (MacBook + Mac mini) 에서 cron sync 가 근접한 시각에 기동되면, 양쪽이
# 동일한 내용으로 origin/next 에 push 해 중복 PR 이 생기는 race 조건이 있다 (증상 #1).
# gieok 의 origin/next 최종 push 시각을 gh CLI 로 확인해 임계 초 이내에
# 다른 run 이 push 를 끝냈다면 이 run 은 조기 exit 해 중복 push 를 회피한다.
#
# Config:
#   GIEOK_SYNC_LOCK_MAX_AGE  임계값 (초). 기본 120. 0 을 지정하면 무효화.
#
# Fail-open:
#   - gh auth 실패 / network error / rate limit: 모두 현상 유지 (guard skip).
#   - 어느 한쪽 Mac 에서 gh 가 무효면 이 guard 는 작동하지 않음. trade-off 로 수용.
#
# Design:
#   - --dry-run 에서는 skip (operator 가 수동 검증할 때 guard 로 막지 않도록).
#   - `git fetch` 직후에 호출한다. branch checkout 보다 앞에 넣어
#     push 예정 branch 를 만드는 비용을 조기에 회피한다.
#   - exit 시에는 기존 trap 이 .git-gieok 를 복원한다.
#
# Reference: 합의 기록 plan/claude/26042104_meeting...md ## Resume session 2
# -----------------------------------------------------------------------------
check_github_side_lock() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  local max_age="${GIEOK_SYNC_LOCK_MAX_AGE:-120}"
  (( max_age <= 0 )) && return 0

  local last_push_iso last_push_epoch now_epoch age
  last_push_iso="$(gh api repos/gaebalai/gieok/branches/next \
      --jq .commit.commit.committer.date 2>/dev/null || true)"
  [[ -z "${last_push_iso}" ]] && return 0  # gh 미인증 / network error → fail-open

  last_push_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${last_push_iso}" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -u +%s)"
  age=$(( now_epoch - last_push_epoch ))

  if (( age >= 0 && age < max_age )); then
    echo "  [skip] origin/next was pushed ${age}s ago (<${max_age}s); another sync likely just completed" >&2
    exit 0
  fi
  return 0
}

# -----------------------------------------------------------------------------
# 전제 체크
# -----------------------------------------------------------------------------

if [[ ! -d "${APP_DIR}/.git-gieok" ]]; then
  echo "ERROR: app/.git-gieok not found. Is gieok repo initialized?" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# gieok 레포의 .git 을 복원하고 먼저 next 브랜치로 전환한다 (clean WT 확보)
#
# 중요: rsync 보다 "먼저" branch checkout 을 끝낸다. WT 를 dirty 로 만든 뒤
# checkout 하면 "덮어쓰인다" 며 git 이 abort 하기 때문.
# -----------------------------------------------------------------------------

cd "${APP_DIR}"

# 2026-04-20 MED-f1 fix: 이전 크래시 중에 .git 과 .git-gieok 가 둘 다 남아 있으면
# 다음 번 `mv .git-gieok .git` 이 기존 .git 을 파괴적으로 덮어써 gieok repo 의
# history 가 손상된다. script 선두에서 양립을 detect 하여 abort 한다.
# 해소 절차: rm -rf app/.git (gieok 쪽은 리모트에서 재 clone 으로 복구 가능)
if [[ -d .git && -d .git-gieok ]]; then
  echo "ERROR: app/.git and app/.git-gieok both exist." >&2
  echo "  This is a leftover from a crashed sync-to-app.sh run." >&2
  echo "  Manual recovery required: 'rm -rf $(pwd)/.git' (re-clone gieok from remote if needed)." >&2
  exit 1
fi

# trap 을 먼저 걸어 둔 뒤 rename (rename 실패 시에도 .git-gieok 쪽을 되돌릴 수 있도록)
trap 'cd "${APP_DIR}" && [[ -d .git ]] && mv .git .git-gieok 2>/dev/null || true' EXIT INT TERM HUP
mv .git-gieok .git

# 2026-04-20: 리모트 최신을 fetch 한 뒤 브랜치를 전환한다.
# 이를 하지 않으면 로컬 main / next 가 origin 대비 오래된 상태로 rsync 의
# 차분이 나오거나, 마지막의 `git checkout main` 으로 오래된 commit 으로 돌아가 WT 가
# 어질러진다 (feature 2.2 릴리스 시의 WT drift 문제). fetch 실패는 허용.
git fetch origin --quiet 2>/dev/null || true

# 2026-04-21 NEW-L2 (v0.4.0 Tier B#3): cross-machine race guard.
# gh api 로 origin/next 의 최종 push 시각을 얻어 임계값 이내이면 조기 exit.
# --dry-run / GIEOK_SYNC_LOCK_MAX_AGE=0 에서 skip. gh 에러는 fail-open.
check_github_side_lock

# 2026-04-20: rebase-merge 운용에서 origin/next 의 이력이 rewrite 되는
# (gieok main 으로 rebase-merge 된 commit 이 origin/main 에 존재하고, 로컬
# next 에 남은 pre-rebase commit 과 diverge 되어 PR 이 CONFLICT) 케이스 + WT 가
# parent repo 의 파일 상태 (feature files 보존) 로 checkout next 가
# untracked conflict 로 abort 되는 케이스를 한 번에 해결하기 위해
# "다음 sync 의 출발점은 항상 origin/main" 이라는 ephemeral next 운용으로 통일한다.
# 이 뒤에 곧 rsync 가 WT 를 부모 repo 의 최신 상태로 덮어쓰므로 branch reset 으로
# WT 가 사라져도 손실은 없다 (commit 전 미저장 변경이 있는 경우는 제외).
# 최초 push 는 보통 fast-forward, 두 번째 이후의 rebase-merge 후에는 force-with-lease
# 가 필요하다 (후단 push 로직에서 폴백).
if git show-ref --quiet refs/remotes/origin/main 2>/dev/null; then
  # 2026-04-20 MED-f2 fix: dirty WT (gieok repo 쪽의 미 commit 수작업) 를 감지하면
  # `git stash push` 로 보험을 만든 뒤 force checkout 한다.
  # git stash list 로 나중에 복구 가능.
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    local_dirty_stash=1
    # 2026-04-21 NEW-L1 fix: stash message 에 `$$` (shell PID) 를 섞어서 1초 이내의
    # 연속 호출에서도 message 가 충돌하지 않도록 한다. macOS `date` 는 `%N`
    # (nanosec) 을 지원하지 않으므로 PID 로 유일화한다. `git stash list` 로 recovery 하는
    # operator 가 이력을 구별할 수 있다.
    git stash push -u -m "sync-to-app auto-stash $(date +%Y%m%d-%H%M%S)-pid$$" --quiet 2>/dev/null || true
    echo "  [notice] dirty WT detected; uncommitted changes stashed. Recover with: cd $(pwd) && mv .git-gieok .git && git stash list" >&2
  fi
  # -B: 기존이면 reset, 없으면 create. --force 상당으로 WT 의 untracked 는 제거하지 않지만
  # tracked conflict 가 있어도 origin/main 의 내용으로 덮어쓴다.
  git checkout -B next origin/main --quiet 2>/dev/null || {
    # WT 에 untracked + conflicting files 가 있는 경우의 rescue path:
    # hard reset + clean 으로 강제로 깨끗한 상태로 만든다 (sync 의 용도상 commit
    # 전의 수작업은 stash 완료라서 안전히 덮어쓰기된다).
    git checkout --force -B next origin/main --quiet
  }
else
  # origin/main 을 가져올 수 없는 (최초 clone 전 / fetch 실패) 경우 기존 동작으로 fallback
  if git show-ref --quiet refs/heads/next 2>/dev/null; then
    git checkout next --quiet
  else
    git checkout -b next --quiet
    echo "  [created] next branch"
  fi
fi

# -----------------------------------------------------------------------------
# 파일 동기화 (깨끗한 next 위에 부모 레포의 최신을 올린다 → 차분 = 이번 추가분)
# -----------------------------------------------------------------------------

cd "${BRAIN_DIR}"
echo "=== sync-to-app: copying from parent to app/ ==="

# 동기화 대상 디렉터리
# mcp/ 는 Phase M 에서 추가된 독립 npm 프로젝트. node_modules/ 는 사용자가
# `bash scripts/setup-mcp.sh` 로 도입하므로 rsync 측에서도 제외한다.
# Phase N 에서 추가한 build/ 와 dist/ (MCPB 번들의 빌드 산출물) 도 동일하게 제외.
for dir in hooks scripts templates skills tests mcp; do
  if [[ -d "${BRAIN_DIR}/${dir}" ]]; then
    # 2026-04-20 security-review HIGH-b1 fix:
    # 기존 코드는 `--exclude='.git*'` 였기 때문에 glob 이 `.gitignore` 까지 오폭하여
    # `templates/vault/.gitignore` 가 gieok 에 **한 번도 sync 되지 않은**
    # 상태였다 (v0.3.0 배포 .mcpb 에 기능 2.1 / 2.2 에서 추가된
    # `.cache/`, `.cache/html/`, `.gieok-mcp.lock` 엔트리가 누락).
    # 개별 exclude 로 분리하여 `.gitignore` 는 반드시 sync 대상으로 둔다.
    rsync -a --delete \
      --exclude='.git' \
      --exclude='.git-gieok' \
      --exclude='node_modules' \
      --exclude='build' \
      --exclude='dist' \
      "${BRAIN_DIR}/${dir}/" "${APP_DIR}/${dir}/"
    echo "  [synced] ${dir}/"
  fi
done

# 동기화 대상 파일
for file in SECURITY.md SECURITY.ja.md; do
  if [[ -f "${BRAIN_DIR}/${file}" ]]; then
    cp "${BRAIN_DIR}/${file}" "${APP_DIR}/${file}"
    echo "  [synced] ${file}"
  fi
done

# LICENSE (레포 루트에서)
if [[ -f "${REPO_ROOT}/LICENSE" ]]; then
  cp "${REPO_ROOT}/LICENSE" "${APP_DIR}/LICENSE"
  echo "  [synced] LICENSE"
fi

echo ""

# -----------------------------------------------------------------------------
# 차분 확인 / commit / push
# -----------------------------------------------------------------------------

cd "${APP_DIR}"
git add -A
if git diff --cached --quiet; then
  echo "=== sync-to-app: no changes to sync ==="
  git checkout main --quiet 2>/dev/null || true
  git merge --ff-only origin/main --quiet 2>/dev/null || true
  exit 0
fi

echo "=== changes to sync ==="
git diff --cached --stat
echo ""

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "=== sync-to-app: DRY RUN — no commit made ==="
  # rsync 로 가져온 WT 변경을 파기하고 next 의 HEAD 로 되돌린다
  git reset HEAD --quiet
  git checkout -- .
  git clean -fd >/dev/null
  # 2026-04-20 LOW-f3 fix: DRY_RUN 에서는 next (= origin/main + 출발점) 에 머무르고
  # `main` 으로의 전환은 하지 않는다. operator 가 "dry-run 후의 branch 상태" 에서 다음
  # 예상 state 를 예측하기 쉽게 하기 위해 (이전 구현에서는 main checkout + ff merge
  # 로 국소적 state 변경이 예상 밖의 결과를 불렀다).
  echo "  [dry-run] local next points at origin/main (+ rsync reverted). local main untouched."
  echo "  [dry-run] NOTE: parent repo's app/ working tree now reflects gieok origin/main state,"
  echo "  [dry-run]       which may differ from parent's HEAD (tracked app/). To restore the"
  echo "  [dry-run]       parent-clean view, run: cd $(dirname "${APP_DIR}") && git checkout HEAD -- app/"
  exit 0
fi

# 커밋 + push
git commit -m "sync: update from parent $(date +%Y%m%d-%H%M)" --quiet
# 2026-04-20: 위의 reset --hard 로 local next 를 origin/main 으로 되돌린 경우
# origin/next 는 오래된 이력을 갖고 있으므로 fast-forward push 는 reject 된다.
# --force-with-lease 로 "origin/next 가 예상대로라면 덮어쓰기" 를 명시 (타인의
# 끼어듦은 감지하여 abort 하는 안전판 force). 일반 sync 에서는 noop.
# 2026-04-20 LOW-f1 fix: push 의 3단 폴백이 silent failure 되지 않도록
# 최종 단계의 --force-with-lease 가 실패한 경우 명시적으로 ERROR 를 내고 exit 1.
git push -u origin next --quiet 2>/dev/null \
  || git push --set-upstream origin next --quiet 2>/dev/null \
  || {
    echo "=== sync: fast-forward push failed; attempting force-with-lease ===" >&2
    git push --force-with-lease origin next --quiet || {
      echo "ERROR: sync push failed (origin/next may have diverged or network issue)" >&2
      exit 1
    }
  }

echo ""
echo "=== sync-to-app: pushed to next branch ==="
echo ""
echo "Next steps:"
echo "  1. Review: https://github.com/gaebalai/gieok/compare/main...next"
echo "  2. Merge:  gh pr create --base main --head next --title 'Sync from parent'"
echo "  3. Or:     git checkout main && git merge next && git push"
echo ""

# main 으로 되돌린다 (로컬 main 을 origin/main 으로 fast-forward 하여 WT drift 회피)
#
# 2026-04-20: 로컬 main 이 origin/main 보다 오래되었으면 여기서 checkout 후
# gieok 의 오래된 commit 트리가 app/ WT 에 겹쳐져, 부모 레포에서 보면 app/ 가
# "feature 파일이 대량으로 deleted" 된 상태가 된다 (v0.3.0 릴리스 시의 실피해).
# fetch 는 선두에서 끝내 두었으므로 ff-only merge 로 안전히 따라간다.
git checkout main --quiet 2>/dev/null || true
git merge --ff-only origin/main --quiet 2>/dev/null || true
