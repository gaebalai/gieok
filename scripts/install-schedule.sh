#!/usr/bin/env bash
#
# install-schedule.sh — claude-brain 정기 실행 셋업의 OS 분기 dispatcher (Phase L)
#
# macOS 에서는 install-launchagents.sh 를, Linux/WSL/BSD 에서는 install-cron.sh 를 호출한다.
# uname -s 로 판정만 하는 얇은 래퍼 (YAGNI).
#
# Usage:
#   bash install-schedule.sh [args]
#
# 인자는 그대로 하위 스크립트에 투명하게 전달된다.
# 예:
#   bash install-schedule.sh --dry-run
#   bash install-schedule.sh --force       (macOS 에서만 유효)
#   bash install-schedule.sh --uninstall   (macOS 에서만 유효)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
  Darwin)
    exec bash "${SCRIPT_DIR}/install-launchagents.sh" "$@"
    ;;
  Linux|*BSD|CYGWIN*|MINGW*|MSYS*)
    exec bash "${SCRIPT_DIR}/install-cron.sh" "$@"
    ;;
  *)
    echo "ERROR: unsupported OS: $(uname -s)" >&2
    echo "       Supported: Darwin (macOS) / Linux / *BSD / WSL / Cygwin" >&2
    exit 1
    ;;
esac
