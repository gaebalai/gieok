# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| main branch (latest) | Yes |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via **GitHub Security Advisories**:

1. Go to the [Security tab](../../security/advisories) of this repository
2. Click "Report a vulnerability"
3. Fill in the details using the template below

### What to include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix or mitigation**: Depends on severity (see CVE Classification below)

### CVE Classification

GIEOK 는 다음 심각도 프레임워크를 사용한다 (내부 `security-review/` 용어와 정렬).

| Severity | 기준 | SLA |
|---|---|---|
| **Critical** | 원격 코드 실행, Vault 전체 exfiltration, Vault 경계 외부로의 무인가 임의 쓰기, 배포된 `.mcpb` 또는 플러그인 마켓플레이스 엔트리에 대한 supply-chain 침해 | ASAP (당일 hotfix 목표, out-of-band 릴리스) |
| **High** | 로컬 권한 상승, 부분 Vault exfiltration, tool 무인가 사용을 유발하는 prompt injection, SSRF / DNS rebind 우회, 프로덕션 토큰 포맷의 마스킹 실패, fail-open 보안 가드 | 1주 이내 (패치 릴리스) |
| **Medium** | 비밀이 아닌 로그의 정보 노출, 데이터 손실 없는 DoS, 명시적 탐지가 가능한 무결성 이슈, 공격 전제조건이 성립한 defense-in-depth 간극 | 2주 이내 (다음 릴리스에 번들) |
| **Low** | 직접 exploit 경로 없는 defense-in-depth 약점, 하드닝 기회, 보안 가이던스에 영향을 주는 문서 간극 | 4주 이내 또는 다음 정기 릴리스 |
| **Info** | 설계 관찰, 구체적 PoC 없는 "이론적" 우려, 하드닝 제안 | triage 완료, 릴리스 SLA 없음 |

**프로덕션 공격 표면** (MCP 서버, Hook 스크립트, 추출 파이프라인, auto-ingest cron, 플러그인 마켓플레이스 artifact) 에 영향을 주는 취약점은 **개발자 모드 이슈** (테스트 fixture, 로컬 전용 harness, 개발 스크립트) 보다 우선한다.

### Safe Harbor

보안 연구 커뮤니티를 지지합니다. 다음을 성실히 수행하는 연구자에 대해 법적 조치를 취하지 않습니다.

- 개인정보 침해, 데이터 파괴, 또는 서비스 중단을 회피하기 위한 선의의 노력
- 위에서 안내한 비공개 채널(GitHub Security Advisory 또는 메인테이너 직접 이메일)을 통해서만 취약점을 보고
- 공개 공개 전 합리적 수정 기간 부여(최초 보고로부터 90일, 또는 수정 배포일 중 빠른 쪽)
- 입증에 필요한 최소한을 넘어서는 취약점 악용 금지
- 다른 사용자의 데이터(타인의 GIEOK 설치본 로컬 Vault 내용 포함) 접근 금지

특정 행위가 범위에 해당하는지 불확실한 경우 **테스트 전에 문의해 주세요.** 케이스별로 대상 연구 승인을 기쁘게 제공합니다.

### Coordinated Disclosure Timeline

표준 프로세스:

1. 보고 접수 → 48시간 이내 확인 응답 (GitHub Security Advisory 또는 이메일)
2. 1주 이내 초기 평가 완료 (위 표 기반 심각도 분류)
3. 심각도 SLA 에 따라 수정 개발 및 배포
4. 공개 배포 artifact (`.mcpb` on GitHub Releases, Claude Code 플러그인 마켓플레이스 엔트리) 에 영향을 주는 **Medium 이상** 이슈에 대해 CVE 요청
5. 수정 배포 후 공개 advisory 게시 — 보고자는 advisory, 커밋 메시지, `security-review/findings/` 에 익명 요청이 없는 한 credit 처리됨

특히 민감한 이슈 (예: 여러 downstream 소비자에 걸친 체인 취약점) 의 경우 연구자는 엠바고 연장을 요청할 수 있다. 연구자와 협력하여 책임 있는 공개 일자를 합의한다.

### Out of Scope

다음은 본 정책상 **보안 취약점으로 간주하지 않는다** (단 GitHub Issues 에서의 버그 보고는 환영):

- 로컬 셸 액세스가 필요한 의도적 리소스 고갈을 통한 DoS (예: `session-logs/` 로 디스크 채우기)
- 개발 전용 플래그 또는 테스트 fixture 에서의 발견 (`GIEOK_URL_ALLOW_LOOPBACK=1`, `GIEOK_DRY_RUN=1` 등 — 테스트 전용으로 문서화됨)
- 사용자가 **명시적으로 선택하여 ingest 한** 공격자 제어 HTML 에서 기인하는 `raw-sources/<subdir>/fetched/` 내 이슈 (위협 모델은 `gieok_ingest_url` 실행 전에 사용자가 소스를 검증한다고 가정)
- 이미 vault 전체 쓰기 권한을 가진 머신이 침해되어 있어야 성립하는 이론적 공격

## Security Design

claude-brain is a Hook system that accesses **all Claude Code session I/O**. This section documents the security architecture.

### Threat Model

| Threat | Mitigation |
|---|---|
| API keys/tokens leaking into session logs | Regex masking (`MASK_RULES` in `session-logger.mjs`) covers Anthropic, OpenAI, GitHub, AWS, Slack, Vercel, npm, Stripe, Supabase, Firebase/GCP, Azure, Bearer/Basic auth, URL credentials, PEM keys |
| Session logs pushed to GitHub | `.gitignore` excludes `session-logs/`. SessionEnd git hook verifies `.gitignore` integrity before committing |
| Hook script tampering | `install-hooks.sh --apply` sets `chmod 755` on hook scripts. Only owner can write |
| Shell/XML/JSON injection via OBSIDIAN_VAULT | `validate_vault_path()` rejects shell metacharacters, JSON control characters, and XML special characters |
| Prompt injection via session logs in auto-ingest | `claude -p` runs with `--allowedTools Write,Read,Edit` only (no Bash). LLM cannot execute shell commands |
| Recursive logging (subprocess logs itself) | `GIEOK_NO_LOG=1` env var + cwd-in-vault check (double guard) |
| qmd MCP exposing data on LAN | Binds to `127.0.0.1` only. Logs written to `~/.local/log/` (not `/tmp/`) |
| Insecure file permissions on shared systems | `session-logs/` created with `0o700`, files with `0o600`. `setup-vault.sh` sets `umask 077` |
| session-logs searchable via qmd | `brain-logs` collection is opt-in only (`setup-qmd.sh --include-logs`) |
| Non-portable binary checks | PATH binary ownership check uses POSIX `ls -ln \| awk` (works on macOS and Linux) |
| **공격 URL을 통한 SSRF** (기능 2.2, `gieok_ingest_url`) | `mcp/lib/url-security.mjs` + `url-fetch.mjs`의 2단 가드: 사전 해석으로 localhost / RFC1918 / link-local / AWS/GCP metadata / IPv4-mapped IPv6 / 10진·16진·8진 IP 표기 / URL credentials를 reject, resolved IP를 DNS lookup에 pin하여 redirect / DNS rebinding도 차단 |
| **redirect 시 scheme downgrade** (기능 2.2) | HTTPS → HTTP 강등 redirect를 명시적으로 탐지하여 reject (`url-fetch.mjs`) |
| **robots.txt bypass** (기능 2.2) | `mcp/lib/robots-check.mjs`를 MCP tool 진입점 + `extractAndSaveUrl`에서 이중 enforce. 명시적 opt-out은 `GIEOK_URL_IGNORE_ROBOTS=1` + 기동 시 stderr WARN |
| **fetched HTML로부터의 prompt injection** (기능 2.2) | Mozilla Readability는 visible body만 추출(script / style / noscript는 strip). LLM fallback은 `claude -p --allowedTools Write(<absCacheDir>/llm-fb-*.md)` + chdir + 최소 child env(아래 "자식 프로세스 env allowlist" 참조) |
| **`.cache/html/`에 공격 HTML이 잔존** (기능 2.2) | `.cache/` + `.cache/html/`을 `templates/vault/.gitignore`로 제외, dir `0o700` / file `0o600`, 파일명은 `urlToFilename` sanitizer(SAFE_PATH_RE 호환) 거친 후 realpath join |
| **공격 HTML의 이미지가 Vault를 비대화** (기능 2.2) | `raw-sources/**/fetched/media/`를 git-ignore(로컬은 Obsidian 표시를 위해 남기되 Git에는 포함하지 않음). MIME whitelist(jpeg/png/webp/gif), SVG / 1×1 tracking pixel은 skip, 이미지당 20 MB cap |
| **child env에 SSRF/robots bypass 플래그가 누출** (기능 2.2, HIGH-d1 fix) | `mcp/lib/child-env.mjs`에서 exact-match allowlist. `GIEOK_URL_*` / `GIEOK_EXTRACT_*` / `GIEOK_ALLOW_EXTRACT_*`는 **propagate하지 않음**. 내부 플래그(`GIEOK_NO_LOG` / `GIEOK_MCP_CHILD` / `GIEOK_DEBUG` / `GIEOK_LLM_FB_*`)만 child MCP / `claude -p`에 전달 |
| **HTML meta 태그를 통한 frontmatter 비밀 정보 누출** (기능 2.2) | `applyMasks`를 body + `title` / `tags` / `byline` / `site_name` / `source_type` / `og_image` / `published_time` / `source_final_url` / `source_host` / `warnings` 모두에 적용(`url-extract.mjs#buildFrontmatterObject`) |
| **MCP 에러 메시지에 내부 IP / URL 누출** (기능 2.2) | `mapFetchErrorAndThrow`(`ingest-url.mjs` / `url-extract-cli.mjs`)는 security 관련 code(`dns_private` / `url_scheme` 등)에서 에러 코드만 반환. attacker-controlled 문자열이 Claude context나 cron log로 흘러가지 않음 |

### File Permission Model

| Path | Permission | Set by |
|---|---|---|
| `session-logs/` (directory) | `0o700` | `session-logger.mjs` (`mkdir`) |
| `session-logs/*.md` (log files) | `0o600` | `session-logger.mjs` (`writeFile` with `flag: 'wx'`) |
| `session-logs/.claude-brain/` | `0o700` | `session-logger.mjs` (`mkdir`) |
| `session-logs/.claude-brain/index.json` | `0o600` | `session-logger.mjs` (`writeFile`) |
| `hooks/session-logger.mjs` | `0o755` | `install-hooks.sh --apply` |
| `hooks/wiki-context-injector.mjs` | `0o755` | `install-hooks.sh --apply` |
| Vault directories (`wiki/`, etc.) | `umask 077` | `setup-vault.sh` |

### Adding New Token Patterns

When you start using a new cloud service, add its token pattern to both files:

1. **`hooks/session-logger.mjs`** — `MASK_RULES` array (JavaScript regex)
2. **`scripts/scan-secrets.sh`** — `PATTERNS` array (ERE regex)

The two arrays must stay in sync. `scan-secrets.sh` detects tokens that `session-logger.mjs` failed to mask.

### Security Review History

Comprehensive security reviews are documented in [`security-review/`](security-review/):

- **2026-04-16 (Round 1)**: 14 vulnerabilities found (1 critical, 6 high, 4 medium, 2 low). All fixed.
- **2026-04-16 (Round 2)**: 9 new findings (0 critical, 0 high, 3 medium, 6 low). 7 fixed, 2 accepted.
- **2026-04-16 (Round 3 — OSS readiness)**: 15 findings with OSS distribution as threat model. 8 fixed (incl. LICENSE, timezone, umask), 7 accepted.
- **2026-04-16 (Round 4 — Red/Blue Team)**: 7 findings from parallel Red Team + Blue Team review. All fixed.
- **2026-04-16 (Round 5 — Final verification)**: Red Team and Blue Team independently confirmed all fixes. 0 new vulnerabilities. **LGTM: Ready for publish.**
- **2026-04-17 (Round 6 — 기능 2 Red/Blue)**: PDF/MD ingest + MCP trigger (기능 2 + 2.1). 발견 사항은 모두 merge 전에 대응 완료(VULN-020..028). 회의록: [`security-review/meeting/2026-04-17_feature-2-red-blue.md`](security-review/meeting/2026-04-17_feature-2-red-blue.md).
- **2026-04-20 (Round 7 — 기능 2.2 code-quality + Red/Blue)**: URL/HTML ingest(`gieok_ingest_url`). code-quality reviewer가 CRIT-1(late-PDF binary refetch) + HIGH-1/2/3 + MED-1/3/4/5를 발견. Red × Blue 병렬 review로 수정 후 HIGH=0 / MEDIUM=0 확인, v0.3.0은 이 기반으로 릴리스.
- **2026-04-20 (v0.3.0 post-release — 차분 + 경계 리뷰)**: v0.3.0 merge 후 cross-tool 통합 및 신규 데이터 경로 review. HIGH 5건(배포 .gitignore 동기화 버그 / 공격 이미지의 Git 유입 / `GIEOK_` child env leak / SECURITY.md drift / `gieok_delete` orphan wikilink scope gap)을 v0.3.1 hotfix로 수정. 상세: [`security-review/findings/2026-04-20_v0-3-0-post-release-review.md`](security-review/findings/2026-04-20_v0-3-0-post-release-review.md).

### Network Policy

Hook scripts (`session-logger.mjs`, `wiki-context-injector.mjs`) do **not** import `http`, `https`, `net`, or `dgram`. All network operations (git pull/push) are performed by shell one-liners in the Hook configuration, not by Node.js code.

**Phase M / gieok-wiki MCP server**: MCP 서버 (`mcp/server.mjs`) 는 별도 프로세스로 실행되며 번들된 `@modelcontextprotocol/sdk` 를 import 할 수 있다. **stdio 전송만 사용** — `server.mjs` 또는 `tools/*.mjs` / `lib/*.mjs` 어디에도 `http`/`https`/`net`/`dgram` import 는 없다. 서버는 stdin 에서 JSON-RPC 메시지를 읽어 stdout 에 쓰며, 부모 클라이언트 (Claude Desktop / Claude Code) 가 유일한 상대이다. 따라서 "stdlib only" 정책은 **Hook 스크립트** 에 scope 되며, MCP 서버는 SDK 의존성을 지닐 수 있는 독립 프로세스 경계로 취급한다.

### Phase M Write Boundaries

MCP 서버는 이전에는 존재하지 않았던 쓰기 경로를 추가한다. 매트릭스:

| Caller | 쓰기 대상 | Permissions | 경계 검사 |
|---|---|---|---|
| Hook (`session-logger.mjs`) | `session-logs/` | dir 0700 / file 0600 | (path-internal) |
| cron (`auto-ingest.sh`, `auto-lint.sh`) | `wiki/` | Vault perms 상속 | (MCP gate 없음) |
| MCP `gieok_write_note` | `session-logs/` | dir 0700 / file 0600 | `assertInsideSessionLogs(rel)` |
| MCP `gieok_write_wiki` | `wiki/` | file 0600 (atomic via tmpfile + rename) | `assertInsideWiki(rel)` |
| MCP `gieok_delete` | `wiki/` → `wiki/.archive/` | dir 0700 (archive) | `assertInsideWiki(rel)` + `wiki/index.md` reject |
| MCP `gieok_ingest_pdf` (기능 2.1) | `.cache/extracted/` + `wiki/summaries/` | dir 0700 / file 0600 | `assertInsideRawSources` + 확장자 whitelist + `withLock` |
| MCP `gieok_ingest_url` (기능 2.2) | `raw-sources/<subdir>/fetched/` | dir 0700 / file 0600 | `assertInsideRawSourcesSubdir` + atomic tmp+rename |
| MCP `gieok_ingest_url` (images) | `raw-sources/<subdir>/fetched/media/<host>/` | file 0600 / sha256-named | MIME whitelist + hostname traversal guard + git-ignored |
| MCP `gieok_ingest_url` (raw HTML cache) | `.cache/html/` | dir 0700 / file 0600 | `urlToFilename` sanitizer (SAFE_PATH_RE 호환) + git-ignored |

경계 교차 쓰기 (예: `gieok_write_wiki` 가 `session-logs/` 를 가리키는 경우) 는 realpath 단계에서 거부된다. 모든 wiki/ 쓰기는 `$VAULT/.gieok-mcp.lock` (advisory flock, 30초 TTL) 을 통해 직렬화되어 MCP 와 `auto-ingest.sh` 가 충돌하지 않는다. `gieok_ingest_url` 은 PDF 를 디스크에 쓴 후 outer `withLock` 을 조기 해제 (초 단위) 하고 `gieok_ingest_pdf` 를 호출하며, 이는 추출 단계에 대해 자체 `withLock` 을 획득한다 — 큰 PDF 에서도 공유 lock 보유 시간이 제한된다 (v0.4.0 Tier A#3 리팩터; 이전의 `skipLock` 주입은 제거됨). `MASK_RULES` (`session-logger.mjs` 미러) 는 모든 `body` 인수 **및** URL 파생 frontmatter 필드에 영속화 전에 적용된다.

### Outbound Network Policy (기능 2.2)

기능 2.2 는 코드베이스에서 최초의 outbound HTTP/HTTPS 호출을 도입한다. 이는 명시적 `gieok_ingest_url` 도구 호출과 cron URL pre-step 으로만 제한되며, Hook 스크립트와 핵심 MCP 도구는 계속해서 네트워크 import 가 **없다.**

- Host ↔ IP 핀닝: DNS lookup 은 앞에서 한 번 수행되고 해석된 IP 는 `isPrivateIP` / `isLoopbackIP` / `isLinkLocalIP` 및 메타데이터 엔드포인트와 대조 검증되며, 이후 핀닝된 IP 를 반환하는 커스텀 `lookup` 으로 `fetch` 가 호출된다 — 따라서 redirect 가 내부 주소로 rebind 될 수 없다.
- 모든 redirect hop 은 `validateUrl` 로 다음 URL 을 재검증하고 DNS 핀닝을 다시 실행하여, 30x 체인을 통한 지연 SSRF 를 방지한다.
- Caps: `DEFAULT_MAX_BYTES` 5 MB (HTML) / 50 MB (PDF), `DEFAULT_TIMEOUT_MS` 30 s, `DEFAULT_MAX_REDIRECTS` 5. 모두 `envPositiveInt` 경유로 env 에서 읽으므로 `=""` / `=NaN` 은 안전 기본값으로 폴백한다 (misconfiguration 시 fail-closed).

### Child Process Env Allowlist (기능 2.1+2.2, HIGH-d1 fix 2026-04-20)

MCP 서버는 두 개의 도구에 대해 자식 프로세스를 spawn 한다:
- `gieok_ingest_pdf` → `extract-pdf.sh` (chunking) + `claude -p` (요약)
- `gieok_ingest_url` (fallback path) → `claude -p` with `--allowedTools Write` chroot

비밀 / 보안 플래그가 자식 컨텍스트로 누출되지 않도록 `mcp/lib/child-env.mjs` 는 **엄격한 allowlist** 를 적용한다:

- Exact-match 전용: `PATH / HOME / USER / LOGNAME / SHELL / TERM / TZ / LANG / LC_ALL / LC_CTYPE / TMPDIR / NODE_PATH / NODE_OPTIONS / OBSIDIAN_VAULT / GIEOK_NO_LOG / GIEOK_MCP_CHILD / GIEOK_DEBUG / GIEOK_LLM_FB_OUT / GIEOK_LLM_FB_LOG`
- Prefix match 전용: `ANTHROPIC_*` (claude CLI auth), `CLAUDE_*` (claude CLI 설정), `XDG_*` (config dir 해석)
- **제외됨**: 모든 `GIEOK_URL_*` / `GIEOK_EXTRACT_*` / `GIEOK_ALLOW_EXTRACT_*` / `GIEOK_INGEST_MAX_SECONDS`. 이들은 전파될 경우 SSRF / robots / bash-override 가드를 silent 하게 해제할 수 있는 테스트 또는 운영자 플래그이다.

이 defense-in-depth 는 테스트 fixture 가 프로덕션으로 누출될 위험 (예: 개발자가 `~/.zprofile` 에 `GIEOK_URL_ALLOW_LOOPBACK=1` 을 남기는 경우) 에 대응한다. 부모가 누출되어도 자식은 깨끗하다.

`scripts/install-mcp-client.sh` 는 `--apply` 일 때만 `~/Library/Application Support/Claude/claude_desktop_config.json` 에 쓴다. `jq` 로 멱등 병합을 수행하고, `OBSIDIAN_VAULT` 를 `^[a-zA-Z0-9/._[:space:]-]+$` 에 대해 검증하며, 손상된 JSON 은 건드리지 않고, `.bak.YYYYMMDD-HHMMSS` 백업을 생성한다.
