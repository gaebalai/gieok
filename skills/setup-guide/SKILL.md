---
name: setup-guide
description: "gieok 의 대화형 셋업 가이드. `/setup-guide` 로 기동. 각 단계의 의미와 의도를 설명하면서, 사용자 환경에 맞춰 설치 작업을 순서대로 진행한다. 처음 쓰는 사용자도 헤매지 않도록 설계되어 있다."
---

# gieok 셋업 가이드

gieok 설치를 **대화 형식**으로 순서대로 진행하는 스킬.
각 단계에서 "무엇을 하는가" "왜 필요한가" 를 설명하고, 사용자의 입력을 기다린 뒤 다음으로 진행한다.

## 진행 방식

- 사용자의 환경 (OS, Node 버전 관리 도구, 기존 Vault 의 유무) 을 최초에 확인한다
- 각 단계는 사용자의 "됐음" "다음으로" 등의 확인을 기다린 뒤 진행한다
- 에러가 발생한 경우는 트러블슈팅을 수행한다
- 스킵 가능한 단계는 명시한다

## 단계 일람

### Step 0: 환경 확인

다음을 사용자에게 확인하거나 자동 검출한다:

1. **OS**: macOS / Linux / WSL 중 어떤 것인가
2. **Node.js**: `node --version` 을 실행하여 18+ 인지 확인. 미설치라면 설치 안내
3. **Git**: `git --version` 을 확인
4. **jq**: `jq --version` 을 확인. 없으면 `brew install jq` 등을 안내
5. **Claude Code**: `claude --version` 을 확인. Max 플랜인지는 사용자에게 확인
6. **Obsidian**: 설치 완료 여부를 사용자에게 확인 (명령으로는 확인 불가)
7. **Node 버전 관리 도구**: Volta / mise / nvm / fnm / asdf / 없음 중 어떤 것인가

결과를 정리해 표시하고, 문제가 있으면 해결한 뒤 다음으로 진행한다.

```
✅ macOS 15.2
✅ Node.js v22.0.0 (Volta)
✅ Git 2.44.0
✅ jq 1.7.1
✅ Claude Code 1.x (Max 플랜)
⚠️ Obsidian 미확인 → https://obsidian.md/ 에서 설치해 주세요
```

### Step 1: Vault 의 생성과 Git 연결 (사용자 작업)

**무엇을 하는가**: Obsidian 에서 새 Vault 를 만들고, GitHub Private 저장소와 연결한다.

**왜 필요한가**: gieok 은 Obsidian Vault 안에 세션 로그와 Wiki 를 저장한다. Git 으로 관리하면 여러 머신 간의 동기화와 백업이 자동화된다.

**순서**:
1. Obsidian 을 열고 "Create new vault" 를 선택
   - 이름: `main-gieok` (임의)
   - 위치: `~/gieok/` (권장. `~/Documents/` 는 macOS 의 TCC 로 백그라운드 접근이 차단되므로 피한다)
2. GitHub 에서 Private 저장소를 생성
3. Vault 디렉터리에서 Git 을 초기화

사용자의 GitHub CLI 유무에 따라 명령을 구분해서 출력한다:

```bash
# gh CLI 가 있는 경우 (간단)
cd ~/gieok/main-gieok
gh repo create gieok --private --source=. --push

# gh CLI 가 없는 경우 (수동)
cd ~/gieok/main-gieok
git init
git remote add origin git@github.com:<USERNAME>/gieok.git
git add -A && git commit -m "initial" && git push -u origin main
```

**확인**: `git remote -v` 로 origin 이 설정되어 있음을 확인한다.

### Step 2: 환경 변수 설정

**무엇을 하는가**: `OBSIDIAN_VAULT` 환경 변수에 Vault 경로를 설정한다.

**왜 필요한가**: gieok 의 모든 스크립트가 이 변수를 참조해 Vault 의 위치를 안다. Hook 스크립트도 Claude Code 에서 실행될 때 이 변수를 사용한다.

**순서**: 사용자의 쉘 (zsh / bash) 을 검출해 적절한 파일에 추가한다.

```bash
# ~/.zshrc (macOS 기본) 또는 ~/.bashrc 에 추가
echo 'export OBSIDIAN_VAULT="$HOME/gieok/main-gieok"' >> ~/.zshrc
source ~/.zshrc
```

**확인**: `echo $OBSIDIAN_VAULT` 로 올바른 경로가 표시됨을 확인.

### Step 3: Vault 의 초기화

**무엇을 하는가**: Vault 내에 디렉터리 구조 (`session-logs/`, `wiki/`, `raw-sources/` 등) 와 초기 파일 (`CLAUDE.md`, `.gitignore`, 템플릿) 을 배치한다.

**왜 필요한가**: gieok 의 Hook 과 스크립트는 특정 디렉터리 구성을 전제로 동작한다. `.gitignore` 는 `session-logs/` (기밀 데이터를 포함) 을 Git 에서 제외하기 위해 필수.

**순서**:

```bash
bash tools/gieok/scripts/setup-vault.sh
```

**확인**: `ls $OBSIDIAN_VAULT` 로 디렉터리 구조를 확인.

### Step 4: Hook 설치

**무엇을 하는가**: Claude Code 의 `~/.claude/settings.json` 에 Hook 설정을 추가한다.

**왜 필요한가**: Hook 이 Claude Code 의 이벤트 (사용자의 입력, AI 의 응답, 도구 사용, 세션 종료) 를 포착해 세션 로그에 기록한다. 이것이 gieok 자동 기록의 핵심.

**순서**:

```bash
# 자동 머지 (권장)
bash tools/gieok/scripts/install-hooks.sh --apply

# diff 가 표시된다. 내용을 확인하고 y 로 적용
```

**이 명령이 하는 일**:
- 기존 `~/.claude/settings.json` 의 백업을 생성
- gieok 의 Hook 엔트리를 기존 설정에 머지 (기존 설정은 덮어쓰지 않음)
- diff 를 표시하고 확인을 요구

**확인**: Claude Code 를 재시작하고, 어떤 대화든 1개 하고 나서, `ls $OBSIDIAN_VAULT/session-logs/` 에 파일이 생성되는지 확인.

---

**여기까지가 필수 단계입니다.** 아래는 선택 사항이지만 권장 사항입니다.

---

### Step 5: 정기 실행 셋업 (권장)

**무엇을 하는가**: 세션 로그를 Wiki 에 수집하는 정기 작업 (Ingest: 매일) 과, Wiki 의 건전성 체크 (Lint: 매월) 를 설정한다.

**왜 필요한가**: 수동으로 Ingest 를 실행하지 않아도, 매일 자동으로 세션 지식이 Wiki 에 축적된다. Lint 는 Wiki 의 품질을 유지한다.

**순서**:

```bash
# 우선 DRY RUN 으로 동작 확인 (실제로는 아무것도 하지 않음)
GIEOK_DRY_RUN=1 bash tools/gieok/scripts/auto-ingest.sh
GIEOK_DRY_RUN=1 bash tools/gieok/scripts/auto-lint.sh

# 문제없으면 정기 실행을 설정
bash tools/gieok/scripts/install-schedule.sh
```

**OS 에 따른 동작**:
- macOS: LaunchAgent 가 `~/Library/LaunchAgents/` 에 배치된다
- Linux: cron 엔트리가 출력된다 (수동으로 `crontab -e` 에 추가)

Step 0 에서 검출한 Node 버전 관리 도구가 Volta / mise 이외의 경우는, `auto-ingest.sh` 와 `auto-lint.sh` 의 PATH 설정을 안내한다.

### Step 6: qmd 검색 엔진 (선택)

**무엇을 하는가**: Wiki 를 MCP 경유로 전문 검색·시맨틱 검색 가능하도록 한다.

**왜 필요한가**: Wiki 가 커지면 index.md 만으로는 다 찾을 수 없다. qmd 는 BM25 + 벡터 검색으로 관련 페이지를 고정밀도로 찾는다.

**전제**: `npm install -g @tobilu/qmd` 가 필요.

```bash
bash tools/gieok/scripts/setup-qmd.sh
bash tools/gieok/scripts/install-qmd-daemon.sh
```

### Step 7: Wiki Ingest 스킬 (선택)

**무엇을 하는가**: `/wiki-ingest-all` 과 `/wiki-ingest` 슬래시 커맨드를 쓸 수 있도록 한다.

**왜 필요한가**: 기존 프로젝트의 지식을 한 번에 Wiki 에 수집할 수 있다.

```bash
bash tools/gieok/scripts/install-skills.sh
```

### 완료

셋업 완료 후, 다음 정리를 표시한다:

```
🎉 gieok 셋업이 완료되었습니다!

✅ Vault: $OBSIDIAN_VAULT
✅ Hook: ~/.claude/settings.json 에 설정 완료
✅ 정기 실행: [LaunchAgent / cron / 미설정]
✅ qmd: [설정 완료 / 미설정]
✅ Wiki Ingest 스킬: [설정 완료 / 미설정]

다음에 할 일:
1. Claude Code 를 재시작한다
2. 평소대로 코딩한다 (자동으로 기록됩니다)
3. 다음날, Obsidian 에서 wiki/ 를 열어 지식이 축적되어 있는지 확인한다
```
