---
title: Install GIEOK as a Claude Code Plugin
updated: 2026-04-24
---

# GIEOK as a Claude Code Plugin

GIEOK 는 3 가지 설치 방법이 있습니다:

| 방법 | 용도 | 대상 |
|---|---|---|
| **1. `.mcpb` bundle** | Claude Desktop / Claude Code (GUI) 로의 drag & drop | 최종 사용자, 최속 |
| **2. Claude Code plugin (본 문서)** | `claude plugin install` 명령으로 install / update | 개발자, 버전 관리 중시 |
| **3. Manual setup** | repo clone + `install-hooks.sh` | contributor, 커스터마이즈 운용 |

본 문서는 **방법 2 (plugin install)** 을 안내합니다. 방법 1 은 [README](../README.md), 방법 3 은 [README #Quick-Start](../README.md#🚀-인터랙티브-설정) 를 참조.

## 전제 조건

- Claude Code (Max plan) 설치됨
- `claude` CLI 가 PATH 에 있음 (`claude --version` 으로 확인)
- Obsidian Vault 1 개 준비 (어느 폴더든 가능, iCloud Drive 불필요)

## 방법 A: marketplace 경유로 설치

```bash
# 1. marketplace 등록 (최초 1회)
claude marketplace add gaebalai/gieok

# 2. plugin install
claude plugin install gieok@gaebalai-marketplace

# 3. 동작 확인
claude plugin list | grep gieok
# => gieok  0.6.0  (installed)
```

## 방법 B: repo 를 직접 지정해 설치

```bash
claude plugin install github:gaebalai/gieok
```

## Post-install 절차

plugin install 은 **skills / hooks / scripts 를 Claude Code 의 discover path 에 배치** 할 뿐, Vault 초기화는 자동화되지 않습니다. 아래를 추가로 실행하세요:

### 1. 환경 변수 설정

```bash
# ~/.zshrc (macOS zsh) 또는 ~/.bashrc (Linux bash) 에 추가
export OBSIDIAN_VAULT="$HOME/gieok/main-gieok"
```

### 2. Vault 초기화

```bash
# 신규 Vault 인 경우에만
mkdir -p "$OBSIDIAN_VAULT"
cd "$OBSIDIAN_VAULT" && git init
gh repo create --private --source=. --push  # GitHub Private repo 생성

# GIEOK 의 Vault 구조 전개 (멱등, 기존 파일은 덮어쓰지 않음)
bash ~/.claude/plugins/gieok/scripts/setup-vault.sh
```

### 3. Hook 을 `~/.claude/settings.json` 에 머지

```bash
bash ~/.claude/plugins/gieok/scripts/install-hooks.sh --apply
# 백업 생성 → diff 표시 → 확인 프롬프트 → 기존 설정을 보존하며 Hook 추가
```

### 4. LaunchAgent / cron 으로 정기 Ingest (선택)

```bash
# OS 자동 판별 (macOS → LaunchAgent / Linux → cron)
bash ~/.claude/plugins/gieok/scripts/install-schedule.sh
```

### 5. MCP 서버를 Claude Desktop 에 등록 (선택, Claude Code skills + Desktop 양쪽에서 쓰는 경우)

```bash
# 의존성 setup
bash ~/.claude/plugins/gieok/scripts/setup-mcp.sh

# Claude Desktop 에 등록
bash ~/.claude/plugins/gieok/scripts/install-mcp-client.sh --apply
```

## 동작 확인

Claude Code 를 재시작한 뒤 대화를 1개 발생시킵니다:

```bash
# GIEOK 관리 하의 Vault 에 session log 가 만들어져야 함
ls "$OBSIDIAN_VAULT/session-logs/" | tail -1
# => 20260424-170000-xxxx-<첫 프롬프트>.md 가 최신
```

Hot cache 기능 확인 (v0.5.1 이후):

```bash
# 새 세션에서 hot.md 가 자동 주입되는지 verify
cat "$OBSIDIAN_VAULT/wiki/hot.md"
# => frontmatter + "## Recent Context" 가 들어있음

# context compaction (`/compact` 로 수동 발화) 후 재주입되는지
# GIEOK_DEBUG=1 로 stderr 에 크기 log 가 나옴
export GIEOK_DEBUG=1
```

## Bases 대시보드 (v0.6 신규)

`bash scripts/setup-vault.sh` 를 실행하면 `wiki/meta/dashboard.base` 가 배치됩니다. Obsidian 에서 열어 9개 뷰 (Hot Cache / Active Projects / Recent Activity / Concepts / Decisions / Analyses / Patterns / Bugs / Stale Pages) 로 Vault 를 한눈에 볼 수 있습니다.

## 멀티 에이전트 (v0.6 신규)

Codex CLI / OpenCode / Gemini CLI 에도 같은 skills 세트를 symlink 로 배포:

```bash
bash ~/.claude/plugins/gieok/scripts/setup-multi-agent.sh
```

## Upgrade

```bash
claude plugin upgrade gieok
```

GIEOK 는 SemVer 을 따릅니다. major bump (0.x → 1.0) 에서 breaking change 가 있는 경우 Release note 에 `BREAKING:` 을 명시합니다.

## Uninstall

```bash
# 1. plugin 제거
claude plugin uninstall gieok

# 2. Hook 설정을 수동으로 제거
# ~/.claude/settings.json 에서 GIEOK 관련 hook entry 를 제거
# (install-hooks.sh 의 backup 이 ~/.claude/settings.json.backup.<timestamp> 에 있어 복원 가능)

# 3. LaunchAgent (macOS 의 경우)
launchctl unload ~/Library/LaunchAgents/com.gieok.ingest.plist
launchctl unload ~/Library/LaunchAgents/com.gieok.lint.plist
rm ~/Library/LaunchAgents/com.gieok.*.plist

# 4. (선택) Vault 삭제
# rm -rf "$OBSIDIAN_VAULT"  # 주의: knowledge base 도 사라짐
```

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `claude plugin install` 에서 not found | marketplace 미등록 | `claude marketplace add gaebalai/gieok` 를 먼저 실행 |
| session log 가 생성되지 않음 | Hook 이 `~/.claude/settings.json` 에 없음 | `install-hooks.sh --apply` 재실행 |
| hot.md 가 LLM 에 도달하지 않음 | `$OBSIDIAN_VAULT` env 미설정 / Vault 외 심볼릭 링크 escape | `echo $OBSIDIAN_VAULT` 로 확인, `realpath` 로 link 대상 확인 |
| auto-ingest 가 안 움직임 | LaunchAgent / cron 미설치 | `install-schedule.sh` 실행 / `launchctl list | grep gieok` 로 확인 |
| `.mcpb` 쪽과 plugin 쪽 충돌 | 양쪽 설치됨 | 하나로 통일 (본 문서의 방법 2 권장 시 `.mcpb` 를 Claude Desktop 에서 uninstall) |

## 관련 문서

- [README](../README.md) — 프로덕트 개요
- [SECURITY.md](../SECURITY.md) — 보안 정책 (CVE / Safe Harbor / Disclosure Timeline)

## 링크

- Repository: https://github.com/gaebalai/gieok
- Releases: https://github.com/gaebalai/gieok/releases
- Issues: https://github.com/gaebalai/gieok/issues
