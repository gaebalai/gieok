#!/usr/bin/env bash
#
# gieok — one-liner bootstrap installer
#
#   curl -fsSL https://raw.githubusercontent.com/gaebalai/gieok/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/gaebalai/gieok/main/install.sh | bash -s -- --yes
#   GIEOK_VAULT=~/my-vault curl -fsSL .../install.sh | bash -s -- --minimal
#
# Flags:
#   --yes / -y           non-interactive; take defaults; install all optional steps
#   --minimal            core only (skip schedule, qmd, skills)
#   --vault PATH         set OBSIDIAN_VAULT (default: ~/gieok/main-gieok)
#   --install-dir PATH   where to clone the repo (default: ~/.local/share/gieok/repo)
#   --ref REF            git branch / tag to check out (default: main)
#   --uninstall          run reverse steps (LaunchAgent unload, hook entries, skill symlinks)
#   -h / --help          show this message and exit
#
# Env vars (flags win over env):
#   GIEOK_VAULT, GIEOK_INSTALL_DIR, GIEOK_REF, GIEOK_YES=1, GIEOK_MINIMAL=1
#
# Exit codes:
#   0  success
#   1  prerequisite missing / invalid input
#   2  clone or step failure
#   3  user cancelled

set -euo pipefail

# ----------------------------------------------------------------------------
# constants & defaults
# ----------------------------------------------------------------------------
REPO_URL="https://github.com/gaebalai/gieok.git"
DEFAULT_INSTALL_DIR="${HOME}/.local/share/gieok/repo"
DEFAULT_VAULT="${HOME}/gieok/main-gieok"
DEFAULT_REF="main"

INSTALL_DIR="${GIEOK_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
VAULT="${GIEOK_VAULT:-${OBSIDIAN_VAULT:-${DEFAULT_VAULT}}}"
REF="${GIEOK_REF:-${DEFAULT_REF}}"
ASSUME_YES="${GIEOK_YES:-0}"
MINIMAL="${GIEOK_MINIMAL:-0}"
UNINSTALL=0

# ----------------------------------------------------------------------------
# color helpers (only when stdout is a tty)
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s▶%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()    { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()   { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
section() { printf '\n%s== %s ==%s\n' "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"; }

die() { err "$*"; exit 1; }

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
}

# ----------------------------------------------------------------------------
# argument parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        ASSUME_YES=1; shift ;;
    --minimal)       MINIMAL=1; shift ;;
    --vault)         VAULT="${2:?--vault requires a PATH}"; shift 2 ;;
    --install-dir)   INSTALL_DIR="${2:?--install-dir requires a PATH}"; shift 2 ;;
    --ref)           REF="${2:?--ref requires a BRANCH/TAG}"; shift 2 ;;
    --uninstall)     UNINSTALL=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1 (use --help)" ;;
  esac
done

# ----------------------------------------------------------------------------
# tty helpers — reads user input from /dev/tty when stdin is piped (curl|bash)
# ----------------------------------------------------------------------------
if [[ -e /dev/tty ]]; then
  HAS_TTY=1
else
  HAS_TTY=0
fi

prompt() {
  # prompt "Question" "default" -> echoes the chosen value
  local q="$1" def="${2:-}"
  local reply
  if [[ "${ASSUME_YES}" == "1" || "${HAS_TTY}" != "1" ]]; then
    printf '%s\n' "${def}"
    return 0
  fi
  if [[ -n "${def}" ]]; then
    printf '%s [%s]: ' "${q}" "${def}" >/dev/tty
  else
    printf '%s: ' "${q}" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || reply=""
  printf '%s\n' "${reply:-${def}}"
}

confirm() {
  # confirm "Question?" "Y|N" -> exit 0 if yes
  local q="$1" def="${2:-Y}"
  local hint="[Y/n]"; [[ "${def}" == "N" ]] && hint="[y/N]"
  if [[ "${ASSUME_YES}" == "1" ]]; then
    [[ "${def}" == "Y" ]]
    return
  fi
  if [[ "${HAS_TTY}" != "1" ]]; then
    [[ "${def}" == "Y" ]]
    return
  fi
  printf '%s %s ' "${q}" "${hint}" >/dev/tty
  local reply=""
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-${def}}"
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

# ----------------------------------------------------------------------------
# prerequisite check
# ----------------------------------------------------------------------------
check_version_node() {
  local v; v="$(node -v 2>/dev/null | sed 's/^v//')" || return 1
  local major="${v%%.*}"
  [[ -n "${major}" && "${major}" -ge 18 ]]
}

row() {
  # row "label" "status" "detail"
  local label="$1" status="$2" detail="$3"
  local badge
  case "${status}" in
    ok)   badge="${C_GREEN}OK  ${C_RESET}" ;;
    miss) badge="${C_RED}MISS${C_RESET}" ;;
    warn) badge="${C_YELLOW}WARN${C_RESET}" ;;
    *)    badge="${status}" ;;
  esac
  printf '  %b  %-18s %s%s%s\n' "${badge}" "${label}" "${C_DIM}" "${detail}" "${C_RESET}"
}

prereq_check() {
  section "Prerequisite check"
  local missing=0

  if command -v bash >/dev/null 2>&1; then
    row "bash" ok "$(bash --version | head -1)"
  else
    row "bash" miss "required"; missing=1
  fi

  if command -v git >/dev/null 2>&1; then
    row "git" ok "$(git --version)"
  else
    row "git" miss "required"; missing=1
  fi

  if command -v node >/dev/null 2>&1; then
    if check_version_node; then
      row "node" ok "$(node -v) (>= 18)"
    else
      row "node" miss "need >= 18 (found $(node -v 2>/dev/null || echo none))"; missing=1
    fi
  else
    row "node" miss "required (>= 18)"; missing=1
  fi

  if command -v claude >/dev/null 2>&1; then
    row "claude" ok "$(claude --version 2>/dev/null | head -1 || echo 'installed')"
  else
    row "claude" miss "Claude Code CLI required"; missing=1
  fi

  if command -v jq >/dev/null 2>&1; then
    row "jq" ok "$(jq --version)"
  else
    row "jq" miss "required for hook merge"; missing=1
  fi

  # optional
  if command -v pdfinfo >/dev/null 2>&1 && command -v pdftotext >/dev/null 2>&1; then
    row "poppler" ok "pdfinfo+pdftotext (optional)"
  else
    row "poppler" warn "optional; needed for PDF ingest"
  fi

  if command -v qmd >/dev/null 2>&1; then
    row "qmd" ok "$(qmd --version 2>/dev/null | head -1 || echo 'installed') (optional)"
  else
    row "qmd" warn "optional; enables full-text search"
  fi

  if [[ ${missing} -gt 0 ]]; then
    err "missing required prerequisites. Install them and re-run."
    case "$(uname -s)" in
      Darwin) say "  macOS hint: ${C_DIM}brew install git node jq poppler${C_RESET}" ;;
      Linux)  say "  Debian/Ubuntu: ${C_DIM}sudo apt install git nodejs jq poppler-utils${C_RESET}" ;;
    esac
    say "  Claude Code: ${C_DIM}https://docs.claude.com/claude-code${C_RESET}"
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# step: clone or update repo
# ----------------------------------------------------------------------------
clone_or_update() {
  section "Fetch repository"
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "existing checkout at ${INSTALL_DIR} — updating"
    git -C "${INSTALL_DIR}" fetch --tags origin
    git -C "${INSTALL_DIR}" checkout "${REF}"
    git -C "${INSTALL_DIR}" pull --ff-only origin "${REF}" || warn "fast-forward pull failed; keeping current checkout"
  else
    if [[ -e "${INSTALL_DIR}" ]]; then
      die "install dir ${INSTALL_DIR} exists but is not a git checkout. Remove it or choose --install-dir PATH."
    fi
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    info "cloning ${REPO_URL} -> ${INSTALL_DIR}"
    git clone --branch "${REF}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  fi
  ok "repo ready at ${INSTALL_DIR}"
}

# ----------------------------------------------------------------------------
# step: vault
# ----------------------------------------------------------------------------
run_setup_vault() {
  section "Setup Vault"
  info "vault path: ${VAULT}"
  mkdir -p "${VAULT}"
  OBSIDIAN_VAULT="${VAULT}" bash "${INSTALL_DIR}/scripts/setup-vault.sh"
  ok "vault initialized"
}

# ----------------------------------------------------------------------------
# step: hooks
# ----------------------------------------------------------------------------
run_install_hooks() {
  section "Install Claude Code hooks"
  OBSIDIAN_VAULT="${VAULT}" bash "${INSTALL_DIR}/scripts/install-hooks.sh" --apply --yes
  ok "hooks merged into ~/.claude/settings.json"
}

# ----------------------------------------------------------------------------
# step: schedule (optional in --minimal)
# ----------------------------------------------------------------------------
run_install_schedule() {
  section "Install schedule (LaunchAgent / cron)"
  OBSIDIAN_VAULT="${VAULT}" bash "${INSTALL_DIR}/scripts/install-schedule.sh" || {
    warn "schedule install returned non-zero; check output above"
    return 0
  }
  ok "schedule installed"
}

# ----------------------------------------------------------------------------
# step: qmd (optional)
# ----------------------------------------------------------------------------
run_setup_qmd() {
  section "Setup qmd search"
  if ! command -v qmd >/dev/null 2>&1; then
    warn "qmd not found on PATH — skipping. Install qmd and re-run with this step."
    return 0
  fi
  OBSIDIAN_VAULT="${VAULT}" bash "${INSTALL_DIR}/scripts/setup-qmd.sh"
  OBSIDIAN_VAULT="${VAULT}" bash "${INSTALL_DIR}/scripts/install-qmd-daemon.sh" || warn "qmd daemon install failed"
  ok "qmd search ready"
}

# ----------------------------------------------------------------------------
# step: skills (optional)
# ----------------------------------------------------------------------------
run_install_skills() {
  section "Install slash-command skills"
  bash "${INSTALL_DIR}/scripts/install-skills.sh"
  ok "skills symlinked to ~/.claude/skills/"
}

# ----------------------------------------------------------------------------
# uninstall path
# ----------------------------------------------------------------------------
do_uninstall() {
  section "Uninstall"
  if [[ ! -d "${INSTALL_DIR}" ]]; then
    warn "no checkout at ${INSTALL_DIR}; nothing to run scripts from"
  else
    case "$(uname -s)" in
      Darwin)
        info "unloading LaunchAgents"
        bash "${INSTALL_DIR}/scripts/install-launchagents.sh" --uninstall || warn "LaunchAgent uninstall returned non-zero"
        ;;
      *)
        warn "on Linux, cron entries were printed not installed — remove them manually from crontab"
        ;;
    esac
    if [[ -d "${INSTALL_DIR}/scripts/install-qmd-daemon.sh" ]] || [[ -f "${INSTALL_DIR}/scripts/install-qmd-daemon.sh" ]]; then
      bash "${INSTALL_DIR}/scripts/install-qmd-daemon.sh" --uninstall 2>/dev/null || true
    fi
  fi

  # hook entries: safest is manual — jq-based removal is fragile
  warn "hook entries in ~/.claude/settings.json were NOT auto-removed."
  warn "remove them manually if desired; the entries reference ${INSTALL_DIR}/hooks/*.mjs"

  # skills: remove symlinks that point into our INSTALL_DIR
  if [[ -d "${HOME}/.claude/skills" ]]; then
    info "removing skill symlinks pointing into ${INSTALL_DIR}"
    while IFS= read -r -d '' link; do
      target="$(readlink "${link}" 2>/dev/null || true)"
      if [[ -n "${target}" && "${target}" == "${INSTALL_DIR}"* ]]; then
        rm -f "${link}" && ok "removed ${link}"
      fi
    done < <(find "${HOME}/.claude/skills" -maxdepth 2 -type l -print0 2>/dev/null)
  fi

  # the repo itself stays — user removes it if they want
  say ""
  say "To remove the repo checkout itself, run:"
  say "  ${C_DIM}rm -rf \"${INSTALL_DIR}\"${C_RESET}"
  say ""
  say "Vault data at ${VAULT} was left untouched."
  ok "uninstall complete"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
  say ""
  say "${C_BOLD}gieok installer${C_RESET} ${C_DIM}— Memory for Claude Code${C_RESET}"
  say ""

  prereq_check

  if [[ "${UNINSTALL}" == "1" ]]; then
    do_uninstall
    return 0
  fi

  section "Configuration"
  # interactive overrides (skipped under --yes / no tty)
  if [[ "${ASSUME_YES}" != "1" && "${HAS_TTY}" == "1" ]]; then
    VAULT="$(prompt "OBSIDIAN_VAULT" "${VAULT}")"
    INSTALL_DIR="$(prompt "install dir" "${INSTALL_DIR}")"
    REF="$(prompt "git ref (branch/tag)" "${REF}")"
  fi

  # validate vault path chars (same rules as setup-vault.sh)
  if [[ ! "${VAULT}" =~ ^[a-zA-Z0-9/._[:space:]-]+$ ]]; then
    die "OBSIDIAN_VAULT contains unsafe characters: ${VAULT}"
  fi

  say ""
  say "  vault         : ${C_BOLD}${VAULT}${C_RESET}"
  say "  install dir   : ${C_BOLD}${INSTALL_DIR}${C_RESET}"
  say "  ref           : ${C_BOLD}${REF}${C_RESET}"
  say "  mode          : ${C_BOLD}$([[ ${MINIMAL} == 1 ]] && echo minimal || echo full)${C_RESET}"
  say ""

  if ! confirm "proceed?" "Y"; then
    err "cancelled by user"
    exit 3
  fi

  clone_or_update
  run_setup_vault
  run_install_hooks

  if [[ "${MINIMAL}" == "1" ]]; then
    info "minimal mode: skipping schedule, qmd, skills"
  else
    run_install_schedule

    if [[ "${ASSUME_YES}" == "1" ]] || confirm "install qmd full-text search? (requires qmd CLI)" "Y"; then
      run_setup_qmd
    fi

    if [[ "${ASSUME_YES}" == "1" ]] || confirm "install slash-command skills (/wiki-ingest, ...)?" "Y"; then
      run_install_skills
    fi
  fi

  section "Done"
  say "  ${C_GREEN}✓${C_RESET} gieok installed"
  say ""
  say "  ${C_BOLD}Next steps${C_RESET}"
  say "    1. Restart Claude Code so new hooks take effect."
  say "    2. Have a short conversation — a log file should appear under:"
  say "       ${C_DIM}${VAULT}/session-logs/${C_RESET}"
  say "    3. The Wiki builds up over time in:"
  say "       ${C_DIM}${VAULT}/wiki/${C_RESET}"
  say ""
  say "  ${C_BOLD}Useful commands${C_RESET}"
  say "    Update        : ${C_DIM}bash ${INSTALL_DIR}/install.sh${C_RESET}"
  say "    Uninstall     : ${C_DIM}bash ${INSTALL_DIR}/install.sh --uninstall${C_RESET}"
  say "    Docs          : ${C_DIM}${INSTALL_DIR}/README.md${C_RESET}"
  say ""
}

main "$@"
