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
- **Fix or mitigation**: Depends on severity (critical: ASAP, high: 1 week, medium: 2 weeks)

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
