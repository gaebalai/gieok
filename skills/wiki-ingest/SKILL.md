---
name: wiki-ingest
description: "특정 파일·디렉터리, 또는 최근 git 변경을 gieok Wiki 에 수집하는 경량판 ingest. `/wiki-ingest <path>` 로 경로 지정, `/wiki-ingest` 인수 없음으로 최근 커밋 차분을 대상으로 한다. 일상적인 단발 ingest 용도. 프로젝트 전체를 일괄 투입하고 싶을 때는 `/wiki-ingest-all` 을 사용한다."
---

# wiki-ingest

특정 파일 or 최근 git 변경으로부터 지식을 추출해 gieok Wiki 에 수집하는 스킬. `/wiki-ingest-all` 의 경량판이며, 일상적으로 마음에 걸리는 부분만 Wiki 에 남기기 위해 사용한다.

## 언제 사용하는가

- 특정 파일/디렉터리의 지식만 Wiki 에 추가하고 싶을 때
- 최근 git 차분에서 설계 판단이나 버그 수정의 지식을 줍고 싶을 때
- `/wiki-ingest-all` 만큼 거창하게 할 필요가 없을 때

프로젝트 전체를 backfill 하고 싶은 경우는 `/wiki-ingest-all` 을 사용할 것.

## 전제

- `$OBSIDIAN_VAULT` 가 설정되어 있고, `$OBSIDIAN_VAULT/wiki/` 가 존재할 것
- 인수 없음 모드는 git 저장소 내에서 실행할 것

## 모드 판정

### 모드 A: 경로 지정 (`/wiki-ingest <path>`)

인수에 1개 이상의 경로 (파일 or 디렉터리) 가 넘어오면 이 모드.

```bash
# 예
/wiki-ingest src/auth/strategy.ts
/wiki-ingest docs/architecture/
/wiki-ingest src/middleware/ src/utils/errors.ts
```

### 모드 B: git 차분 (`/wiki-ingest` 인수 없음)

인수가 비어 있으면 이 모드. 최근 git 변경에서 Claude 가 판단해 지식을 추출한다.

## 워크플로

### Step 0: 환경 확인

`/wiki-ingest-all` 의 Step 0 과 동일:

```bash
test -n "$OBSIDIAN_VAULT" || echo "ERROR: OBSIDIAN_VAULT not set"
test -d "$OBSIDIAN_VAULT/wiki" || echo "ERROR: wiki/ missing"

PROJECT_NAME=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*/([^/]+)(\.git)?$#\1#' | sed 's/\.git$//')
test -n "$PROJECT_NAME" || PROJECT_NAME=$(basename "$(pwd)")
```

### Step 1: 대상의 결정

#### 모드 A (경로 지정)

- 지정된 경로가 존재하는지 `test -e` 로 확인
- 파일이면 직접 읽는다 (Read)
- 디렉터리면 `ls` 로 내용을 확인하고, 주요한 것 (README, index.*, 설계 문서 등) 을 우선해서 읽는다
- 바이너리/너무 큰 파일은 스킵

#### 모드 B (git 차분)

최근 커밋을 우선 훑어보고 범위를 정한다:

```bash
git log --oneline -10
git status
```

위의 결과를 보고 Claude 가 범위를 판단한다. 고정의 `HEAD~N` 은 사용하지 않는다. 전형적으로는:

- 최근 1~3 커밋에 명확한 테마가 있다 → 그 범위
- 커밋이 자잘하게 흩어져 있다 → 최근 1 커밋만
- 작업 도중 (uncommitted) → `git diff` + `git diff --cached` 만

정해진 범위에서 차분을 취득:

```bash
git diff HEAD~<N>..HEAD --stat       # 우선 개요
git diff HEAD~<N>..HEAD              # 그 다음 본체 (크면 파일 단위로 좁힌다)
```

**스킵하는 변경**:
- lint / format / 오타 수정
- 의존 관계의 단순한 버전 범프
- 파일 이동·리네임뿐인 커밋
- 생성물 (dist/, build/, lock 파일)

### Step 2: 기존 Wiki 감사

`/wiki-ingest-all` 의 Step 0-3 과 동일:

```bash
ls "$OBSIDIAN_VAULT/wiki/projects/"
ls "$OBSIDIAN_VAULT/wiki/concepts/"
ls "$OBSIDIAN_VAULT/wiki/patterns/"
cat "$OBSIDIAN_VAULT/wiki/index.md"
```

qmd MCP 가 이용 가능하면 키워드로 사전 검색 (옵셔널).

### Step 3: 지식의 추출

읽어낸 내용에서 다음을 찾는다:

- **설계 판단**: 왜 이 구조/라이브러리/접근법을 선택했는가
- **버그 수정의 근본 원인**: 왜 그 버그가 일어났는가, 어떻게 고쳤는가
- **새 기술/도구**: 처음 도입한 라이브러리, 설정 방법, 주의점
- **리팩토링의 의도**: 무엇을 개선했는가, 어째서 그 형태가 되었는가
- **성능 개선**: 병목의 특정, 측정 방법, 개선 결과
- **보안 대응**: 취약성의 발견과 대책

### Step 4: Wiki 로의 기록

vault CLAUDE.md 의 "페이지 포맷" 과 "wiki/analyses/ 의 페이지 포맷과 저장 기준" 을 따른다. 기록 위치의 판단:

| 추출한 지식의 성질 | 기록 위치 |
|---|---|
| 이 프로젝트 고유의 설계 판단 | `wiki/projects/<PROJECT_NAME>.md` 에 추가 |
| 다른 프로젝트에서도 통용되는 범용 분석/비교 | `wiki/analyses/<topic>.md` (신규 or 갱신) |
| 다른 프로젝트에서도 사용할 수 있는 설계 패턴 | `wiki/patterns/<pattern>.md` |
| 범용적인 기술 개념 | `wiki/concepts/<concept>.md` |
| 프로젝트 고유의 중대한 설계 선택 | `wiki/decisions/<PROJECT_NAME>-<topic>.md` |

**중복의 취급**: 동일 이름 페이지가 이미 있으면 **신규 작성이 아닌 갱신** 한다 (추가/보강/`updated` 의 재기록). vault CLAUDE.md 의 "중복의 취급" 규칙을 따른다.

기록 후:

1. `wiki/index.md` 에 신규 페이지를 추가
2. `wiki/log.md` 에 기록을 추가:

```markdown
## YYYY-MM-DD HH:MM — wiki-ingest
- Project: <PROJECT_NAME>
- Mode: path | diff
- Input: <지정 경로> | <git diff range>
- Created/Updated: <페이지 일람>
```

### Step 5: 완료 요약

```
✅ wiki-ingest 완료
Mode: <path | diff>
Input: <무엇을 대상으로 했는가>

갱신:
- wiki/xxx/yyy.md
- wiki/index.md
- wiki/log.md

다음 액션:
- 내용을 Obsidian 에서 확인
- 필요하면 /wiki-ingest-all 로 프로젝트 전체를 투입
```

## 보안 규칙

`/wiki-ingest-all` 과 동일. 특히:

- `.env` 의 값을 읽지 않는다
- 인증 정보·토큰·시크릿을 Wiki 에 적지 않는다
- 사내 URL·내부 IP·호스트명을 적지 않는다
- 불안할 때는 적지 않는다

## 스킵 판단의 기준

다음 중 어느 하나에 해당하면 **기록하지 않고 종료**:

- 읽어낸 내용에 Wiki 에 쓸 만큼의 지식이 없다 (단순한 오타 수정, 주석 추가 등)
- 보안 규칙에 저촉되는 내용밖에 없다
- 기존 Wiki 페이지와 완전히 같은 정보밖에 얻을 수 없다

"적을 것이 없다" 도 훌륭한 결론. 무리해서 뭔가 쓰지 않는다.

## `/wiki-ingest-all` 과의 사용 구분

| 용도 | 사용하는 스킬 |
|---|---|
| 프로젝트 전체의 backfill (최초) | `/wiki-ingest-all` |
| 프로젝트 전체의 재스캔 (대규모 개편 후) | `/wiki-ingest-all` |
| 특정 파일의 지식만 추가 | `/wiki-ingest <path>` |
| 최근 git 변경을 줍는다 | `/wiki-ingest` (인수 없음) |
| cron 의 일일 자동 수집 | `auto-ingest.sh` (스킬이 아닌 쉘) |
