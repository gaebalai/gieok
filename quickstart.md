# auto-ingest.sh 실행 방법

## 1. 기본 실행 (수동)

```bash
/Users/사용자경로/Gieok/scripts/auto-ingest.sh
```

## 2. 테스트용 Dry Run (claude 호출 안 함)

```bash
GIEOK_DRY_RUN=1 ./scripts/auto-ingest.sh
```

## 3. cron 자동 실행 (매일 아침 7시)

```cron
0 7 * * * /Users/사용자경로/Gieok/scripts/auto-ingest.sh >> "$HOME/gieok-ingest.log" 2>&1
```

## 주요 환경 변수

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `OBSIDIAN_VAULT` | `$HOME/claude-brain/main-claude-brain` | Vault 루트 경로 |
| `GIEOK_DRY_RUN` | `0` | `1`이면 실제 수집 없이 로그만 |
| `GIEOK_INGEST_MAX_SECONDS` | `1500` | 소프트 타임아웃(초) |
| `GIEOK_LOCK_TTL_SECONDS` | `1800` | Lockfile TTL |
| `GIEOK_LOCK_ACQUIRE_TIMEOUT` | `30` | Lock 획득 대기(초) |

## 전제 조건

- `claude`, `node`, `git` 이 PATH에 있을 것 (스크립트가 mise/Volta shim 자동 추가)
- PDF 수집 시 `poppler` (`pdfinfo`, `pdftotext`) 설치 필요
- Vault 안에 `session-logs/` 또는 `raw-sources/` 디렉터리 존재

## 종료 코드

- `0` : 정상 (미처리 로그 0건 스킵 포함)
- `1` : Vault 없음 / `claude` 명령 없음
