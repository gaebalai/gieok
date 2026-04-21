#!/usr/bin/env bash
#
# install-hooks.sh — claude-brain 의 훅 설정 스니펫을 출력한다
#
# 기본 동작은 사용자의 ~/.claude/settings.json 을 건드리지 않고 stdout 에
# JSON 스니펫을 출력만 하는 안전한 설계. --apply 가 붙은 경우에만
# jq 기반의 멱등 머지 및 쓰기를 수행한다 (open-issues #3).
#
# 사용법:
#   bash install-hooks.sh              # stdout 에 스니펫을 출력 (비파괴)
#   bash install-hooks.sh --apply      # ~/.claude/settings.json 에 머지 (jq 필요)
#   bash install-hooks.sh --apply --yes  # 확인 프롬프트를 건너뛴다
#
# 환경 변수:
#   OBSIDIAN_VAULT           (required) Vault 루트의 절대 경로
#   CLAUDE_SETTINGS_FILE     (optional) 쓰기 대상을 교체 (테스트용).
#                            미설정 시 $HOME/.claude/settings.json
#
# 종료 코드:
#   0  정상 종료
#   1  OBSIDIAN_VAULT 미설정
#   2  --apply 시 jq 를 찾을 수 없음 / 머지 실패 / 사용자가 취소

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_ABS="$(cd "${SCRIPT_DIR}/.." && pwd)/hooks/session-logger.mjs"
INJECTOR_ABS="$(cd "${SCRIPT_DIR}/.." && pwd)/hooks/wiki-context-injector.mjs"

# -----------------------------------------------------------------------------
# 인자 파싱
# -----------------------------------------------------------------------------
APPLY_MODE=0
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --apply) APPLY_MODE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

# VULN-004: OBSIDIAN_VAULT 유효성 검증 (셸 메타 문자・JSON 제어 문자 거부)
validate_vault_path() {
  local p="$1"
  local safe_re='^[a-zA-Z0-9/._[:space:]-]+$'
  if [[ ! "${p}" =~ $safe_re ]]; then
    echo "error: OBSIDIAN_VAULT contains unsafe characters: ${p}" >&2
    echo "       Only alphanumerics, /, ., _, space, and - are allowed." >&2
    exit 1
  fi
}

if [[ -z "${OBSIDIAN_VAULT:-}" ]]; then
  cat >&2 <<'EOF'
error: OBSIDIAN_VAULT is not set.

Please set the environment variable first, e.g.:

  export OBSIDIAN_VAULT="$HOME/claude-brain/main-claude-brain"

Then re-run this script.
EOF
  exit 1
fi

validate_vault_path "${OBSIDIAN_VAULT}"

# -----------------------------------------------------------------------------
# 전제조건 체크 (C.4): 경고만, exit 는 하지 않음
# -----------------------------------------------------------------------------

WARNINGS=()

if [[ ! -d "${OBSIDIAN_VAULT}" ]]; then
  WARNINGS+=("OBSIDIAN_VAULT path does not exist or is not a directory: ${OBSIDIAN_VAULT}")
fi

if [[ -d "${OBSIDIAN_VAULT}" ]]; then
  # Vault 자체 또는 상위 디렉터리 중 하나에 .git 이 있으면 OK (중첩 Vault 대응)
  if ! git -C "${OBSIDIAN_VAULT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    WARNINGS+=("Vault is not inside a git repository. SessionStart pull and SessionEnd push hooks will silently fail until you run 'git init' and configure a remote.")
  fi
fi

if [[ -f "${OBSIDIAN_VAULT}/.gitignore" ]]; then
  if ! grep -q "^session-logs/" "${OBSIDIAN_VAULT}/.gitignore" 2>/dev/null; then
    WARNINGS+=("Vault .gitignore does not contain 'session-logs/'. Run setup-vault.sh first to avoid pushing session logs to GitHub.")
  fi
else
  if [[ -d "${OBSIDIAN_VAULT}" ]]; then
    WARNINGS+=("Vault has no .gitignore. Run setup-vault.sh first.")
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  WARNINGS+=("'node' command not found in PATH. Install Node.js 18+ before enabling hooks.")
fi

if [[ ! -f "${HOOK_ABS}" ]]; then
  WARNINGS+=("Hook script not found at expected path: ${HOOK_ABS}")
fi

if [[ ! -f "${INJECTOR_ABS}" ]]; then
  WARNINGS+=("Wiki context injector not found at expected path: ${INJECTOR_ABS}")
fi

# -----------------------------------------------------------------------------
# JSON 스니펫 생성 함수 (stdout / --apply 양쪽에서 사용)
#
# 변수 전개를 포함하므로 single-quoted heredoc 은 쓸 수 없다는 점에 주의.
# -----------------------------------------------------------------------------

emit_snippet_json() {
  cat <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "cd \"${OBSIDIAN_VAULT}\" && git pull --rebase --quiet 2>/dev/null || true"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "OBSIDIAN_VAULT=\"${OBSIDIAN_VAULT}\" node '${INJECTOR_ABS}'"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OBSIDIAN_VAULT=\"${OBSIDIAN_VAULT}\" node '${HOOK_ABS}'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OBSIDIAN_VAULT=\"${OBSIDIAN_VAULT}\" node '${HOOK_ABS}'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "OBSIDIAN_VAULT=\"${OBSIDIAN_VAULT}\" node '${HOOK_ABS}'"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OBSIDIAN_VAULT=\"${OBSIDIAN_VAULT}\" node '${HOOK_ABS}'"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ \"\${GIEOK_NO_LOG:-0}\" = \"1\" ] || { cd \"${OBSIDIAN_VAULT}\" && grep -q '^session-logs/' .gitignore 2>/dev/null && git symbolic-ref -q HEAD >/dev/null 2>&1 && git add wiki/ raw-sources/ templates/ CLAUDE.md 2>/dev/null && (git diff --cached --quiet || (git commit -m \"auto: wiki update \$(date +%Y%m%d-%H%M)\" --quiet && git push --quiet)) 2>/dev/null; } || true"
          }
        ]
      }
    ]
  }
}
EOF
}

# -----------------------------------------------------------------------------
# --apply: ~/.claude/settings.json 에 멱등 머지
#
# 절차:
#   1. jq 가 없으면 exit 2
#   2. 쓰기 대상 (기본 ~/.claude/settings.json) 을 결정. 없으면 빈 오브젝트로 생성
#   3. 타임스탬프가 붙은 백업 생성
#   4. jq 로 각 이벤트 키마다 "기존 배열에서 동일 command 엔트리 제거 → 새 엔트리 추가"
#      (멱등. 두 번 실행해도 중복되지 않음)
#   5. diff 를 표시하고 사용자 확인 (--yes 로 생략)
#   6. 쓰기
# -----------------------------------------------------------------------------

apply_merge() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required for --apply but was not found in PATH" >&2
    exit 2
  fi

  local target="${CLAUDE_SETTINGS_FILE:-${HOME}/.claude/settings.json}"
  mkdir -p "$(dirname "${target}")"

  if [[ ! -f "${target}" ]]; then
    echo '{}' > "${target}"
    echo "note: created empty ${target}"
  fi

  # 기존 JSON 의 유효성 체크 (손상된 JSON 에 덮어쓰지 않기 위한 안전장치)
  if ! jq -e . "${target}" >/dev/null 2>&1; then
    echo "error: ${target} is not valid JSON. Refusing to touch it." >&2
    exit 2
  fi

  local snippet_file
  snippet_file="$(mktemp)"
  emit_snippet_json > "${snippet_file}"

  if ! jq -e . "${snippet_file}" >/dev/null 2>&1; then
    echo "error: generated snippet is not valid JSON (bug)" >&2
    rm -f "${snippet_file}"
    exit 2
  fi

  local backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "${target}" "${backup}"

  local merged_file
  merged_file="$(mktemp)"

  # 각 이벤트 키에 대해, 기존 배열에서 "새 엔트리와 동일한 command 를 가진 엔트리" 를 제거하고
  # 그 뒤에 새 엔트리를 append 한다 (멱등 머지).
  #
  # 주의: (.hooks[$k][].hooks[0].command) 를 비교 키로 사용.
  # 새 엔트리도 기존도 "hooks: [ { type, command } ]" 형태를 가정.
  jq --slurpfile snippet "${snippet_file}" '
    . as $old |
    ($snippet[0]) as $new |
    ($old.hooks // {}) as $old_hooks |
    ($new.hooks) as $new_hooks |
    reduce ($new_hooks | keys[]) as $k (
      $old;
      .hooks = (
        (.hooks // {}) |
        .[$k] = (
          (((.[$k] // []) |
            map(
              select(
                (.hooks[0].command // "") as $c |
                ([$new_hooks[$k][].hooks[0].command] | index($c)) == null
              )
            )
          ) + $new_hooks[$k])
        )
      )
    )
  ' "${target}" > "${merged_file}"

  if ! jq -e . "${merged_file}" >/dev/null 2>&1; then
    echo "error: merge produced invalid JSON. Backup kept at ${backup}" >&2
    rm -f "${snippet_file}" "${merged_file}"
    exit 2
  fi

  echo "=== diff (old → new) ==="
  diff -u "${target}" "${merged_file}" || true
  echo "========================"
  echo "target:  ${target}"
  echo "backup:  ${backup}"

  if [[ "${ASSUME_YES}" != "1" ]]; then
    printf "Apply this change? [y/N] "
    read -r reply
    case "${reply}" in
      y|Y|yes|YES) ;;
      *)
        echo "aborted. backup left at ${backup}"
        rm -f "${snippet_file}" "${merged_file}"
        exit 2
        ;;
    esac
  fi

  mv "${merged_file}" "${target}"
  rm -f "${snippet_file}"

  # VULN-014: 훅 스크립트의 퍼미션을 제어 (소유자만 쓰기 가능)
  for hook_file in "${HOOK_ABS}" "${INJECTOR_ABS}"; do
    if [[ -f "${hook_file}" ]]; then
      chmod 755 "${hook_file}"
      echo "  chmod 755 ${hook_file}"
    fi
  done

  echo "applied. to rollback: mv ${backup} ${target}"
}

# -----------------------------------------------------------------------------
# --apply 모드 분기
# -----------------------------------------------------------------------------

if [[ "${APPLY_MODE}" == "1" ]]; then
  if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
    echo "WARNINGS:" >&2
    for w in "${WARNINGS[@]}"; do
      echo "  - ${w}" >&2
    done
    echo "(address the warnings above; proceeding with merge anyway)" >&2
  fi
  apply_merge
  exit 0
fi

# -----------------------------------------------------------------------------
# 아래는 기본 stdout 출력 모드 (기존 동작)
# -----------------------------------------------------------------------------

cat <<EOF
# ============================================================================
# claude-brain hook configuration
# ============================================================================
#
# This script DOES NOT modify ~/.claude/settings.json unless you pass --apply.
# Copy the JSON snippet below and merge it into your settings file manually,
# or re-run with --apply to let the script merge it for you (requires jq).
#
# Resolved paths:
#   OBSIDIAN_VAULT  = ${OBSIDIAN_VAULT}
#   hook script     = ${HOOK_ABS}
#   wiki injector   = ${INJECTOR_ABS}
#
EOF

if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  echo "# WARNINGS:"
  for w in "${WARNINGS[@]}"; do
    echo "#   - ${w}"
  done
  echo "#"
  echo "# Address the warnings above before enabling the hooks."
  echo "#"
fi

cat <<'EOF'
# Design notes (important):
#   - SessionStart chains two commands: first 'git pull --rebase' against the
#     Vault repository, then wiki-context-injector.mjs which outputs
#     { "additionalContext": ... } containing wiki/index.md so Claude picks up
#     the knowledge base automatically at session start.
#   - SessionEnd runs two chained commands: first session-logger.mjs appends
#     the session summary, then 'git add / commit / push' syncs wiki changes.
#   - Normal coding sessions do NOT trigger a push because Hook only writes
#     to session-logs/, which is gitignored. You'll only see commits after
#     running the weekly Ingest command or manually editing wiki/ files.
#     This is by design, not a bug.
#   - All git commands are wrapped with '2>/dev/null || true' to keep hooks
#     fail-safe. Inspect 'git status' in the Vault manually if sync seems off.
#   - The SessionEnd git one-liner short-circuits when GIEOK_NO_LOG=1
#     is set. auto-ingest.sh / auto-lint.sh export this flag before spawning
#     'claude -p', so the subprocess Claude's SessionEnd hook does NOT commit
#     on behalf of the parent cron script (which has its own commit block).
#
# ============================================================================
# JSON snippet to merge into ~/.claude/settings.json
# ============================================================================
EOF

emit_snippet_json

cat <<'EOF'

# ============================================================================
# Merge instructions
# ============================================================================
#
# Option A (easiest, new in open-issues #3):
#
#   bash install-hooks.sh --apply
#
#   This merges the snippet into ~/.claude/settings.json idempotently
#   (running it twice does not duplicate entries) and creates a timestamped
#   backup at ~/.claude/settings.json.bak.YYYYMMDD-HHMMSS.
#
# Option B (manual):
#
#   1. Open ~/.claude/settings.json in your editor.
#   2. Under the "hooks" key, add the entries above. If a key already exists
#      (e.g. you already have a PostToolUse entry), append a new matcher block
#      rather than overwriting.
#   3. Make sure $OBSIDIAN_VAULT is exported in the shell that Claude Code
#      inherits (add it to ~/.zshrc or ~/.bashrc, then restart Claude Code).
#
# Verification:
#
#   After merging, restart Claude Code and run one prompt. Then check:
#     ls "$OBSIDIAN_VAULT/session-logs/"
#   A new Markdown file should appear.
#
EOF
