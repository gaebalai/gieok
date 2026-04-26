# Quickstart — Gieok v0.6.0

## ⚡ 원라이너 설치 (가장 빠름)

Node 18+ 가 설치돼 있으면 이 한 줄로 끝납니다.

```bash
npx gieok
```

> `npx gieok` 는 패키지를 받아 내부의 `install.sh` 를 그대로 실행합니다. `curl | bash` 방식과 플래그 · 기본값이 완전히 동일하며, Node 가 없을 때만 `curl` 경로를 쓰면 됩니다.

```bash
# Node 없이 curl 로 설치
curl -fsSL https://raw.githubusercontent.com/gaebalai/gieok/main/install.sh | bash
```

두 방식 모두 저장소를 `~/.local/share/gieok/repo` 에 clone 하고, Vault(`~/gieok/main-gieok`) 를 초기화한 뒤 Hook · LaunchAgent · 스킬 · qmd 검색까지 한 번에 설치합니다.

```bash
# 완전 비대화형 (기본값으로 모두 설치)
npx gieok --yes

# 코어만 (스케줄 · qmd · skills 제외)
npx gieok --minimal

# Vault 경로 지정
npx gieok --vault ~/my-vault
# 또는
GIEOK_VAULT=~/my-vault npx gieok

# 업데이트 (같은 명령 재실행 — clone 이 아닌 pull 로 갱신)
npx gieok

# 제거 (LaunchAgent / hook 항목 / 스킬 심볼릭 링크 되돌림)
bash ~/.local/share/gieok/repo/install.sh --uninstall
```

설치 후 Claude Code 를 재시작하면 Hook 이 적용됩니다. 전체 옵션은 `npx gieok --help` 로 확인하세요.

### Claude Desktop MCP 번들 (선택)

Claude Desktop 에서 Vault 를 직접 읽고 쓰려면 `.mcpb` 번들을 사용하세요.

```bash
bash ~/.local/share/gieok/repo/scripts/build-mcpb.sh
# → gieok-wiki-0.6.0.mcpb 생성 → Claude Desktop 으로 drag & drop → Vault 디렉터리 지정 → ⌘Q 로 완전 재시작
```

Claude Code / CLI 클라이언트는 직접 등록:

```bash
bash ~/.local/share/gieok/repo/scripts/install-mcp-client.sh
```

### 📦 Claude Code 플러그인 마켓플레이스 (v0.6 신규)

Claude Code 사용자는 대화창에서 슬래시 명령으로 한 번에 설치 가능 (셸 명령이 아님):

```text
/plugin marketplace add gaebalai/gieok
/plugin install gieok@gaebalai-marketplace
```

상세한 post-install 절차(Vault 초기화 · Hook 주입 · 트러블슈팅)는 [docs/install-guide-plugin.md](docs/install-guide-plugin.md) 참조.

### 🤖 멀티 에이전트 (v0.6 신규)

Codex CLI / OpenCode / Gemini CLI 에도 같은 skills 세트를 symlink 로 배포 (멱등):

```bash
bash ~/.local/share/gieok/repo/scripts/setup-multi-agent.sh
```

배포 경로 — Codex `~/.codex/skills/gieok` / OpenCode `~/.config/opencode/skills/gieok` / Gemini `~/.gemini/skills/gieok`. 다른 에이전트에서는 **skills (슬래시 커맨드) 만 동작**하며 자동 세션 캡처는 Claude Code 전용입니다. 자세한 매트릭스는 [README #멀티-에이전트-지원](README.md#-멀티-에이전트-지원-v06-신규) 참조.

---

# auto-ingest.sh 실행 방법

## 1. 기본 실행 (수동)

```bash
~/.local/share/gieok/repo/scripts/auto-ingest.sh
# 직접 clone 한 경우에는 해당 경로로 교체
```

## 2. 테스트용 Dry Run (claude 호출 안 함)

```bash
GIEOK_DRY_RUN=1 bash ~/.local/share/gieok/repo/scripts/auto-ingest.sh
```

## 3. 자동 실행 — macOS LaunchAgent (권장)

```bash
bash ~/.local/share/gieok/repo/scripts/install-schedule.sh
# OS 자동 감지: macOS → LaunchAgent, Linux → cron
```

## 4. cron 수동 설정 (Linux / 참고)

```cron
0 7 * * * ~/.local/share/gieok/repo/scripts/auto-ingest.sh >> "$HOME/gieok-ingest.log" 2>&1
```

## 주요 환경 변수

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `OBSIDIAN_VAULT` | `$HOME/gieok/main-gieok` | Vault 루트 경로 |
| `GIEOK_DRY_RUN` | `0` | `1`이면 실제 수집 없이 로그만 |
| `GIEOK_INGEST_MAX_SECONDS` | `1500` | 소프트 타임아웃(초) |
| `GIEOK_LOCK_TTL_SECONDS` | `1800` | Lockfile TTL |
| `GIEOK_LOCK_ACQUIRE_TIMEOUT` | `30` | Lock 획득 대기(초) |
| `GIEOK_SYNC_LOCK_MAX_AGE` | `120` | v0.5.1: `sync-to-app.sh` GitHub-side race lock TTL (2대 이상 cron 병주 시만 의미 있음) |

## 전제 조건

- `claude`, `node`, `git` 이 PATH 에 있을 것 (스크립트가 mise / Volta / Homebrew / MacPorts shim 자동 추가)
- PDF 수집 시 `poppler` (`pdfinfo`, `pdftotext`) 설치 필요 — `brew install poppler`
- Vault 안에 `session-logs/` 또는 `raw-sources/` 디렉터리 존재

## URL / PDF 수집 (MCP 경유)

Claude Desktop / Claude Code 에서 다음처럼 말하면 자동으로 Vault 에 들어갑니다.

```
이 아티클 읽고 정리해줘: https://example.com/article
이 PDF 요약해줘: /path/to/paper.pdf
```

긴 PDF (chunk 2개 이상) 는 MCP 가 즉시 `queued_for_summary` 를 반환하고 백그라운드에서 요약을 생성합니다 — 1~3분 후 `wiki/summaries/` 에 정리본이 나타납니다.

## 종료 코드

- `0` : 정상 (미처리 로그 0건 스킵 포함)
- `1` : Vault 없음 / `claude` 명령 없음
- `2` : Lock 획득 실패
