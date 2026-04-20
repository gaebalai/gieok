---
name: wiki-ingest-all
description: "현재 프로젝트 전체를 망라적으로 탐색하여, 설계 판단·기술 선택·아키텍처·패턴·실패 사례를 gieok Wiki 에 일괄 투입한다. `/wiki-ingest-all` 로 기동. 기존 프로젝트의 backfill (Wiki 에 아직 기록되지 않은 과거 지식을 1회로 수집) 이 주 용도. 신규 프로젝트를 처음으로 Wiki 에 올릴 때도 사용할 수 있다. 토큰 소비를 신경 쓰지 않고 깊이 탐색하는 전제."
---

# wiki-ingest-all

현재 작업 디렉터리 (`$(pwd)`) 에 있는 프로젝트를 망라적으로 읽어들이고, gieok Wiki (`$OBSIDIAN_VAULT/wiki/`) 에 지식을 기록하는 스킬.

## 언제 사용하는가

- 기존 프로젝트의 지식을 **처음으로** Wiki 에 수집할 때 (backfill)
- 프로젝트의 전체상을 1회로 Wiki 에 기록하고 싶을 때
- 새 프로젝트를 시작해 최초에 구조를 Wiki 에 고정하고 싶을 때

같은 프로젝트에 대해 2회째 이후의 실행은 **갱신 모드** 로 취급하며, 기존 페이지를 교체하지 않고 추가·보강한다.

## 전제

- `$OBSIDIAN_VAULT` 가 설정되어 있고, `$OBSIDIAN_VAULT/wiki/` 가 존재할 것
- 현재 커런트 디렉터리가 대상 프로젝트의 루트일 것
- 최초 실행이라면, Wiki 는 비어 있거나 최소한의 상태를 상정 (qmd/중복 체크는 그 전제로 동작함)

## 워크플로

### Step 0: 환경 확인과 기존 Wiki 감사

최초에 다음을 전부 실행한다. 1개라도 빠지면 사용자에게 지시를 요청하고 중단.

```bash
# 0-1. Vault 확인
test -n "$OBSIDIAN_VAULT" || echo "ERROR: OBSIDIAN_VAULT not set"
test -d "$OBSIDIAN_VAULT/wiki" || echo "ERROR: wiki/ missing; run setup-vault.sh first"

# 0-2. 프로젝트명 결정
PROJECT_NAME=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*/([^/]+)(\.git)?$#\1#' | sed 's/\.git$//')
test -n "$PROJECT_NAME" || PROJECT_NAME=$(basename "$(pwd)")
echo "Project: $PROJECT_NAME"

# 0-3. 기존 Wiki 의 감사 (중복 회피를 위해)
ls "$OBSIDIAN_VAULT/wiki/projects/" 2>/dev/null
ls "$OBSIDIAN_VAULT/wiki/concepts/" 2>/dev/null
ls "$OBSIDIAN_VAULT/wiki/patterns/" 2>/dev/null
ls "$OBSIDIAN_VAULT/wiki/decisions/" 2>/dev/null
ls "$OBSIDIAN_VAULT/wiki/analyses/" 2>/dev/null
cat "$OBSIDIAN_VAULT/wiki/index.md"
```

**판단**: `wiki/projects/${PROJECT_NAME}.md` 가 이미 존재하는 경우는 **갱신 모드**. 신규 작성이 아닌 기존 페이지에 추가/보강한다 (기존 내용을 파괴하지 않는다).

### Step 0.5: qmd 검색 (이용 가능한 경우만)

qmd MCP 도구 (`mcp__qmd__query`) 가 이용 가능하면, 프로젝트명이나 주요 디렉터리명으로 사전 검색해 기존의 관련 페이지를 발견한다:

```
mcp__qmd__query(
  collection: "brain-wiki",
  searches: [{type: "lex", query: "<PROJECT_NAME>"}],
  intent: "find existing wiki pages about this project"
)
```

qmd 가 쓸 수 없음/0건이어도 실패 취급하지 않는다. Step 0-3 의 `ls` 만으로도 중복 회피는 성립한다.

### Step 1: 프로젝트 전체의 조망

다음을 순서대로 읽는다. node_modules, .git, dist, build, .next, .venv, __pycache__, target, vendor, .DS_Store 는 제외.

```bash
# 파일 전체 모습
git ls-files 2>/dev/null || find . -type f \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/dist/*' \
  -not -path '*/build/*' \
  -not -path '*/__pycache__/*' \
  -not -path '*/target/*' \
  -not -path '*/.venv/*'
```

### Step 2: 정의 파일의 읽기

다음을 존재하는 한 전부 읽는다 (Read 도구):

1. **프로젝트 정의**: `README.md`, `README`, `CLAUDE.md`, `AGENTS.md`, `context.md`, `context/*.md`
2. **기술 스택**: `package.json`, `pnpm-lock.yaml` or `yarn.lock` 의 상위, `Cargo.toml`, `go.mod`, `pyproject.toml`, `Gemfile`, `composer.json`, `build.gradle`, `pom.xml`
3. **설정**: `tsconfig*.json`, `.eslintrc*`, `.prettierrc*`, `biome.json`, `vite.config.*`, `next.config.*`, `webpack.config.*`
4. **인프라**: `Dockerfile`, `docker-compose.yml`, `.github/workflows/*.yml`, `.gitlab-ci.yml`, `terraform/*.tf`
5. **환경 변수**: `.env.example`, `.env.sample`, `.env.template` (**값은 읽지 않는다, 변수명만**)
6. **문서**: `docs/**`, `ADR/**`, `CHANGELOG.md`, `ARCHITECTURE.md`
7. **엔트리 포인트**: `src/index.*`, `src/main.*`, `app/page.*`, `cmd/*/main.go`, `lib/index.*`

### Step 3: 아키텍처 탐색

`src/`, `app/`, `lib/`, `pkg/`, `internal/` 등의 메인 디렉터리를 1계층씩 읽고, 다음을 파악:

- 레이어 구조 (MVC / clean architecture / hexagonal 등)
- 라우팅 방식 (file-based / decorator / 명시 등록)
- 데이터 액세스 계층 (ORM / 생 SQL / repository pattern)
- 인증/인가의 엔트리 포인트
- 에러 핸들링의 공통 처리
- 미들웨어/인터셉터

너무 커서 전부 읽을 수 없는 경우는 **주요 엔트리 포인트에서 의존을 쫓는** 방식으로 한다. 파일을 전부 grep 으로 핥으려 하지 않는다.

### Step 4: 테스트 구성

`tests/`, `__tests__/`, `spec/`, `*.test.*`, `*.spec.*` 의 배치와, 테스트 프레임워크 (jest, vitest, pytest, go test, rspec 등) 를 확인. 커버리지 설정 (`jest.config`, `vitest.config`) 이 있으면 읽는다.

### Step 5: 체크포인트 (대화 확인)

여기서 한 번 사용자에게 요약을 제시한다:

> 「프로젝트 **<PROJECT_NAME>** 을 탐색했습니다. 다음을 추출할 예정입니다:
>
> - 프로젝트 페이지: `wiki/projects/<PROJECT_NAME>.md` (신규/갱신)
> - 기술 스택: ...
> - 아키텍처 패턴: ...
> - 신규 작성 예정인 concept/pattern/decision 페이지:
>   - `wiki/concepts/xxx.md`
>   - `wiki/patterns/yyy.md`
> - 기존 페이지로의 추가 예정: (Step 0-3 에서 찾은 것)
>
> 이대로 기록해도 괜찮습니까? (yes / 일부 스킵 / 취소)」

사용자 승인을 얻고 나서 Step 6 으로 진행. token 을 아끼지 않는 설계이므로 여기는 **반드시** 끼운다.

### Step 6: Wiki 로의 기록

vault CLAUDE.md 의 "페이지 포맷" 과 "디렉터리 규약" 을 따라 다음을 기록한다.

#### 6-1. 프로젝트 페이지 (필수, 1장)

**경로**: `wiki/projects/<PROJECT_NAME>.md`

```markdown
---
title: <PROJECT_NAME>
tags: [project, <기술1>, <기술2>]
created: YYYY-MM-DD
updated: YYYY-MM-DD
source: wiki-ingest-all
---

## 개요
(프로젝트의 목적, README 에서 요약)

## 기술 스택
(package.json / Cargo.toml 등에서 열거)

## 아키텍처
(Step 3 의 탐색 결과. 레이어, 라우팅, 데이터 액세스)

## 주요 엔트리 포인트
- `path/to/entry.ts` — <역할>

## 테스트 전략
(프레임워크, 배치, 커버리지 방침)

## 배포/인프라
(Docker, CI/CD, 클라우드 구성)

## 설계 판단 (하이라이트)
- (context.md 나 ADR 에서 주운 판단)

## 알려진 기술 부채
(TODO / FIXME / HACK 중 중요한 것)

## 관련 페이지
- [[<concept1>]]
- [[<pattern1>]]
```

#### 6-2. 범용 concept 페이지 (필요에 따라)

프로젝트 고유가 아닌 **다른 프로젝트에서도 통용되는 개념** (예: `nextjs-app-router`, `prisma-orm`, `bun-runtime`) 은 `wiki/concepts/` 에 쓴다. 이미 존재하면 **갱신**.

#### 6-3. 재이용 가능 pattern 페이지

- 에러 핸들링 미들웨어
- 인증 스트래티지
- DB migration 의 운용
- 등, 코드 중에 반복적으로 나타나는 패턴은 `wiki/patterns/` 에 쓴다

#### 6-4. 설계 판단 decision 페이지

context.md 나 ADR 에 적혀 있는 "왜 이 기술/구성을 선택했는가" 는 `wiki/decisions/<PROJECT_NAME>-<topic>.md` 에 쓴다 (예: `projectA-auth-jwt-vs-session.md`).

#### 6-5. analyses (범용 분석만)

프로젝트를 읽고 **다른 프로젝트에서도 도움 되는 범용 분석** (예: "Prisma vs Drizzle 비교") 이 있으면 `wiki/analyses/` 에. **프로젝트 고유의 상세는 넣지 않는다** (vault CLAUDE.md 의 명확한 구분).

#### 6-6. index.md 의 갱신

신규 페이지를 추가했다면 `wiki/index.md` 의 목차에 1줄씩 추가한다. 기존 엔트리의 순서는 깨지 않는다.

#### 6-7. log.md 로의 기록

`wiki/log.md` 에 Ingest 기록을 추가:

```markdown
## YYYY-MM-DD HH:MM — wiki-ingest-all
- Project: <PROJECT_NAME>
- Created: <count> pages (<list>)
- Updated: <count> pages (<list>)
- Source: <$(pwd)>
```

### Step 7: raw-sources 에 사본을 저장

프로젝트에 `context.md` 나 `CLAUDE.md` 가 있으면, 그 복사본을 `raw-sources/ideas/<PROJECT_NAME>-context.md` 에 저장한다:

```markdown
---
title: <PROJECT_NAME> context (copied YYYY-MM-DD)
source_path: <PROJECT_NAME>/<파일명의 상대 경로>
source_project: <PROJECT_NAME>
copied_by: wiki-ingest-all
copied_at: YYYY-MM-DD
---

(원 파일의 내용을 그대로 복사)
```

**목적**: 나중에 "그 Wiki 페이지의 근거는 무엇인가" 를 추적할 수 있도록 한다.

### Step 8: 완료 요약

마지막에 사용자에게 다음을 표시:

```
✅ wiki-ingest-all 완료
Project: <PROJECT_NAME>

작성한 페이지:
- wiki/projects/<PROJECT_NAME>.md
- wiki/concepts/xxx.md
- wiki/patterns/yyy.md

갱신한 페이지:
- wiki/index.md
- wiki/log.md
- (기존 페이지가 있으면 그것도)

raw-sources 에 사본: raw-sources/ideas/<PROJECT_NAME>-context.md (있으면)

다음 액션:
- Obsidian 에서 확인
- 다른 프로젝트로 cd 해서 다시 /wiki-ingest-all
```

## 보안 규칙 (엄수)

vault CLAUDE.md 의 보안 규칙을 전부 지킨다. 특히 이 스킬 고유:

- `.env`, `.env.local`, `*.pem`, `*.key`, `id_rsa`, `credentials.json`, `secrets.yaml` 등은 **절대 읽지 않는다**
- `.env.example` / `.env.sample` 은 변수명만 기록, 값은 기록하지 않는다
- 코드 중에 하드코딩된 토큰/API 키를 찾아도 Wiki 에 옮기지 않는다 (오히려 "하드코딩된 인증 정보 있음" 이라는 경고만 쓴다)
- 사내 URL, 내부 IP, 호스트명은 기록하지 않는다
- 데이터베이스 접속 문자열의 실제 값은 기록하지 않는다

불안할 때는 **쓰지 않는다** 를 선택한다. Wiki 는 **지식** 을 저장하는 장소이며, **인증 정보** 를 저장하는 장소가 아니다.

## 운용 가이드: 10 프로젝트를 backfill 하는 흐름

```bash
# 1개째: 우선 1 프로젝트로 시도
cd ~/projects/projectA
# Claude Code 에서 /wiki-ingest-all
# → Step 5 의 체크포인트에서 출력을 음미
# → 문제없으면 yes 로 Step 6 에 진행

# Obsidian 에서 wiki/projects/projectA.md 를 눈으로 확인

# 2개째 이후: 패턴이 굳어지면 연속 실행
cd ~/projects/projectB
# /wiki-ingest-all
# (이하, projectC, projectD, ... 반복)

# 완료 후, MacBook 에서 commit & push
cd "$OBSIDIAN_VAULT/.."
git status
git add main-gieok/wiki/ main-gieok/raw-sources/
git commit -m "wiki: backfill N projects via wiki-ingest-all"
git push
```

**사고를 막는 요령**: 최초의 1 프로젝트는 반드시 체크포인트 (Step 5) 를 활성화해 출력을 음미한다. 2개째부터는 흘려보내는 판단을 해도 된다.

## `/wiki-ingest` 와의 사용 구분

| 용도 | 사용하는 스킬 |
|---|---|
| 프로젝트 전체를 1회로 Wiki 에 올린다 | `/wiki-ingest-all` (이 스킬) |
| 특정 파일만 Wiki 에 반영 | `/wiki-ingest <path>` |
| 최근 git 변경만 Wiki 에 반영 | `/wiki-ingest` (인수 없음) |

## 트러블슈팅

- **Vault 가 너무 비어 있어 어떻게 써야 할지 모르겠다**: vault CLAUDE.md 의 "페이지 포맷" 절을 읽는다. 그것을 따라 쓰면 된다
- **기존 프로젝트 페이지와 충돌했다**: 갱신 모드로 기존을 존중하면서 신규 정보를 추가한다. 기존 정보를 삭제하지 않는다
- **거대한 모노레포로 전부 읽을 수 없다**: Step 3 에서 "주요 엔트리 포인트에서 의존을 쫓는" 방식으로 전환한다. 전부 읽으려 하지 않는다
- **프로젝트명이 취득되지 않는다**: 사용자에게 묻는다 (예: "이 프로젝트의 Wiki 상의 이름은 무엇으로 할까요?")
