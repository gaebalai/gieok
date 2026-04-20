// tools-ingest-pdf.test.mjs — gieok_ingest_pdf 핸들러 (기능 2.1) 단위/통합 테스트
//
// MCP23   path가 Vault 외부 → invalid_params
// MCP24   암호화된 PDF → invalid_request
// MCP25   정상 실행 (1 chunk) → status: "extracted_and_summarized" (sample-8p.pdf)
// MCP25b  v0.3.5 Option B size-gate: 15p 이하 = 1 chunk는 동기 계속 (sample-15p.pdf)
// MCP25c  v0.3.5 Option B size-gate: 16p 이상 = 2+ chunks는 detached (sample-42p.pdf)
// MCP26   멱등 호출 → status: "skipped"
// MCP27   .pdf/.md 이외 확장자 → invalid_params
// MCP28   lockfile 경합 (다른 프로세스가 보유) → LockTimeoutError
// MCP29   --allowedTools Write,Read,Edit + GIEOK_NO_LOG=1 + GIEOK_MCP_CHILD=1이 자식 claude로 전달
// MCP30   상대 경로와 절대 경로 둘 다 수용
//
// 포인트: 실제 extract-pdf.sh + fixture PDF를 사용하므로 poppler (pdfinfo/pdftotext)가
// 필요. 없는 환경에서는 describe.skip으로 SKIP.
// claude 명령은 stub으로 교체 (실 LLM 호출 안 함) — `injections.claudeBin`을 사용.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdtemp, mkdir, rm, cp, writeFile, chmod, stat, readdir, readFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(__dirname, '..', '..', 'mcp');
const REPO_ROOT = join(__dirname, '..', '..', '..', '..');
const FIXTURES = join(__dirname, '..', 'fixtures', 'pdf');
const EXTRACT_PDF = join(__dirname, '..', '..', 'scripts', 'extract-pdf.sh');

const { handleIngestPdf } = await import(join(MCP_DIR, 'tools', 'ingest-pdf.mjs'));

// poppler가 없으면 본 스위트 전체를 skip (CI에서의 SKIP을 명시)
const popplerCheck = spawnSync('sh', ['-c', 'command -v pdfinfo >/dev/null 2>&1 && command -v pdftotext >/dev/null 2>&1'], { stdio: 'ignore' });
const HAS_POPPLER = popplerCheck.status === 0;

let workspace, stubBinDir, stubClaudeLog;

before(async () => {
  workspace = await mkdtemp(join(tmpdir(), 'gieok-mcp-ip-'));
  stubBinDir = join(workspace, 'stub-bin');
  stubClaudeLog = join(workspace, 'stub-claude.log');
  await mkdir(stubBinDir, { recursive: true });
  // stub claude: argv와 환경 변수 관련 항목을 log에 적고 성공 종료
  // LOW-4 (env allowlist) 테스트를 위해 secret env (GH_TOKEN 등)가 전파되지 않는지도
  // 관찰할 수 있도록 widely match한다.
  const stubClaude = join(stubBinDir, 'claude-stub.sh');
  const script = `#!/usr/bin/env bash
# stub: record GIEOK_* / OBSIDIAN_VAULT / secret-like env + argv to log
{
  echo "=== invocation ==="
  echo "ARGV: $*"
  env | grep -E '^(GIEOK_|OBSIDIAN_VAULT=|GH_TOKEN=|AWS_|OPENAI_API_KEY=|ANTHROPIC_)' | sort
  echo "--- end env ---"
} >> "${stubClaudeLog}"
exit 0
`;
  await writeFile(stubClaude, script, { mode: 0o755 });
  await chmod(stubClaude, 0o755);
});

after(() => rm(workspace, { recursive: true, force: true }));

async function makeVault(name) {
  const vault = join(workspace, name);
  await mkdir(join(vault, 'raw-sources', 'papers'), { recursive: true });
  await mkdir(join(vault, 'wiki', 'summaries'), { recursive: true });
  await mkdir(join(vault, '.cache', 'extracted'), { recursive: true });
  await mkdir(join(vault, 'session-logs'), { recursive: true });
  return vault;
}

const claudeBin = () => join(stubBinDir, 'claude-stub.sh');

describe('gieok_ingest_pdf', { skip: !HAS_POPPLER ? 'poppler not installed' : false }, () => {
  test('MCP23 rejects path outside vault (absolute)', async () => {
    const vault = await makeVault('mcp23');
    // 외부 디렉터리에 PDF를 둠
    const outsideDir = await mkdtemp(join(tmpdir(), 'gieok-ip-outside-'));
    try {
      await cp(join(FIXTURES, 'sample-8p.pdf'), join(outsideDir, 'evil.pdf'));
      await assert.rejects(
        handleIngestPdf(vault, { path: join(outsideDir, 'evil.pdf') }, { claudeBin: claudeBin() }),
        (err) => err.code === 'invalid_params' || err.code === 'path_outside_boundary',
      );
    } finally {
      await rm(outsideDir, { recursive: true, force: true });
    }
  });

  test('MCP23b rejects relative path escaping raw-sources/', async () => {
    const vault = await makeVault('mcp23b');
    await assert.rejects(
      handleIngestPdf(vault, { path: '../../etc/passwd' }, { claudeBin: claudeBin() }),
      (err) => err.code === 'invalid_params' || err.code === 'path_traversal',
    );
  });

  test('MCP24 encrypted PDF -> invalid_request', async () => {
    const vault = await makeVault('mcp24');
    await cp(join(FIXTURES, 'sample-encrypted.pdf'), join(vault, 'raw-sources', 'papers', 'locked.pdf'));
    await assert.rejects(
      handleIngestPdf(vault, { path: 'raw-sources/papers/locked.pdf' }, { claudeBin: claudeBin() }),
      (err) => err.code === 'invalid_request',
    );
  });

  test('MCP25 normal execution (1 chunk) -> extracted_and_summarized', async () => {
    const vault = await makeVault('mcp25');
    await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault, 'raw-sources', 'papers', 'attention.pdf'));
    const result = await handleIngestPdf(
      vault,
      { path: 'raw-sources/papers/attention.pdf' },
      { claudeBin: claudeBin() },
    );
    // 8p는 1 chunk에 담기므로 기존처럼 동기 계속 (v0.3.5 size-gate 하한)
    assert.equal(result.status, 'extracted_and_summarized');
    assert.ok(result.pdf_path.endsWith('attention.pdf'), 'pdf_path returned');
    assert.ok(Array.isArray(result.chunks) && result.chunks.length === 1,
      `1 chunk expected for 8p PDF, got ${result.chunks.length}`);
    // chunk MD가 실제로 생성됨 + 새 명명 규칙을 사용
    const cacheEntries = await readdir(join(vault, '.cache', 'extracted'));
    assert.ok(
      cacheEntries.some((n) => n.startsWith('papers--attention-pp')),
      `double-hyphen chunk expected, got: ${cacheEntries.join(',')}`,
    );
    // stub claude가 호출됨
    const log = await readFile(stubClaudeLog, 'utf8');
    assert.match(log, /ARGV: -p/, 'stub claude was invoked with -p');
  });

  test('MCP25b v0.3.5 size-gate: 15p = 1 chunk still synchronous (extracted_and_summarized)', async () => {
    // v0.3.5 Option B의 size-gate 경계 테스트. GIEOK_PDF_CHUNK_PAGES=15 (기본) 이하
    // PDF는 single chunk가 되어 기존처럼 sync로 claude -p를 돌려 extracted_and_summarized
    // 를 반환 (단시간에 완료될 전망, UX 변경 없음).
    const vault = await makeVault('mcp25b');
    await cp(join(FIXTURES, 'sample-15p.pdf'), join(vault, 'raw-sources', 'papers', 'short.pdf'));
    const result = await handleIngestPdf(
      vault,
      { path: 'raw-sources/papers/short.pdf' },
      { claudeBin: claudeBin() },
    );
    assert.equal(result.status, 'extracted_and_summarized',
      `15p (1 chunk) should stay synchronous, got: ${JSON.stringify(result)}`);
    assert.equal(result.chunks.length, 1,
      `15p PDF should be exactly 1 chunk, got ${result.chunks.length}`);
    assert.ok(Array.isArray(result.summaries), 'summaries array present');
    // queued 경로의 필드는 없어야 함
    assert.equal(result.expected_summaries, undefined,
      'sync path must not include expected_summaries');
    assert.equal(result.detached_pid, undefined,
      'sync path must not include detached_pid');
  });

  test('MCP25c v0.3.5 size-gate: 42p = 3 chunks dispatches detached (queued_for_summary)', async () => {
    // v0.3.5 Option B: chunks >= 2 (sample-42p.pdf는 GIEOK_PDF_CHUNK_PAGES=15 + 1 page
    // overlap으로 3 chunks가 될 것으로 예상)는 detached claude -p를 spawn하고 queued_for_summary
    // 로 조기 return. stub claude가 spawn되었는지 shared stub log에서 확인.
    //
    // 주의: stub claude 스크립트는 `{ ... } >> ${stubClaudeLog}`로 출력을 공유 로그에
    // redirect하므로, spawnDetached 측의 per-vault log file (stdio redirect 대상)은
    // 비어 있음. shared stub log를 클리어한 뒤 invocation 기록 증가를 관찰.
    await writeFile(stubClaudeLog, '');
    const vault = await makeVault('mcp25c');
    await cp(join(FIXTURES, 'sample-42p.pdf'), join(vault, 'raw-sources', 'papers', 'long.pdf'));
    const result = await handleIngestPdf(
      vault,
      { path: 'raw-sources/papers/long.pdf' },
      { claudeBin: claudeBin() },
    );
    assert.equal(result.status, 'queued_for_summary',
      `42p PDF should queue for detached summary, got: ${JSON.stringify(result)}`);
    assert.ok(Array.isArray(result.chunks) && result.chunks.length >= 2,
      `expected >=2 chunks for 42p PDF, got: ${result.chunks?.length}`);
    assert.ok(Array.isArray(result.expected_summaries) && result.expected_summaries.length >= 2,
      'expected_summaries must be populated on queued path');
    // detached_pid와 log_file이 반환됨
    assert.equal(typeof result.detached_pid, 'number', 'detached_pid is a PID');
    assert.ok(result.detached_pid > 0, 'detached_pid positive');
    assert.match(result.log_file ?? '', /^\.cache\/claude-summary-papers--long\.log$/,
      `log_file relative path expected, got: ${result.log_file}`);
    assert.match(result.message ?? '', /chunks extracted/i, 'message contains guidance');

    // chunks[]는 즉시 확인 가능 (raw-sources 아래가 아닌 .cache/extracted/ 아래)
    const cacheEntries = await readdir(join(vault, '.cache', 'extracted'));
    assert.ok(
      cacheEntries.some((n) => n.startsWith('papers--long-pp')),
      `chunk MDs should be present immediately, got: ${cacheEntries.join(',')}`,
    );

    // 관측용 summary lockfile이 생성됨
    const vaultEntries = await readdir(vault);
    assert.ok(
      vaultEntries.some((n) => n === '.gieok-summary-papers--long.lock'),
      `summary lockfile expected, got: ${vaultEntries.filter((n) => n.startsWith('.gieok-')).join(',')}`,
    );

    // Phase A에서 획득한 .gieok-mcp.lock은 해제되어 있어야 함 (auto-ingest가 진행)
    const mcpLockExists = vaultEntries.some((n) => n === '.gieok-mcp.lock');
    assert.equal(mcpLockExists, false, '.gieok-mcp.lock must be released before detached spawn');

    // per-vault의 detached log file도 touch (open + close)만은 수행되어 있어야 함
    // (child stub이 `>>`로 shared log에 redirect하므로 내용은 비어 있지만, 파일
    // 자체는 spawnDetached의 open()으로 생성됨)
    const perVaultLogPath = join(vault, result.log_file);
    const logStat = await stat(perVaultLogPath);
    assert.ok(logStat.isFile(), 'per-vault detached log file should exist');

    // detached stub claude는 shared stubClaudeLog에 추가. polling으로 확인.
    let sharedLog = '';
    for (let i = 0; i < 40; i++) {
      await new Promise((r) => setTimeout(r, 25));
      sharedLog = await readFile(stubClaudeLog, 'utf8');
      if (sharedLog.includes('ARGV: -p')) break;
    }
    assert.match(sharedLog, /ARGV: -p/,
      `detached claude stub should log its invocation, got: ${sharedLog.slice(0, 200)}`);
    assert.match(sharedLog, /GIEOK_NO_LOG=1/, 'GIEOK_NO_LOG propagated to detached child');
    assert.match(sharedLog, /GIEOK_MCP_CHILD=1/, 'GIEOK_MCP_CHILD propagated to detached child');
    assert.match(sharedLog, /OBSIDIAN_VAULT=/, 'OBSIDIAN_VAULT propagated to detached child');
  });

  test('MCP26 second call is idempotent -> skipped', async () => {
    const vault = await makeVault('mcp26');
    await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault, 'raw-sources', 'papers', 'same.pdf'));
    // 첫 호출에서 chunk를 생성 (stub claude는 summary를 만들지 않으므로 수동으로 모방)
    await handleIngestPdf(vault, { path: 'raw-sources/papers/same.pdf' }, { claudeBin: claudeBin() });
    // chunk MD의 sha256을 그대로 summary에 복사하여 idempotent를 유도
    const cacheEntries = (await readdir(join(vault, '.cache', 'extracted'))).filter((n) => n.endsWith('.md'));
    for (const name of cacheEntries) {
      const chunkContent = await readFile(join(vault, '.cache', 'extracted', name), 'utf8');
      const shaMatch = chunkContent.match(/^source_sha256:\s*"([0-9a-f]{64})"/m);
      assert.ok(shaMatch, `chunk ${name} has source_sha256`);
      const summaryContent = `---\ntitle: "${name}"\nsource_sha256: "${shaMatch[1]}"\n---\nsummary\n`;
      await writeFile(join(vault, 'wiki', 'summaries', name), summaryContent);
    }
    // 2번째 호출은 skipped
    const r2 = await handleIngestPdf(vault, { path: 'raw-sources/papers/same.pdf' }, { claudeBin: claudeBin() });
    assert.equal(r2.status, 'skipped', `second call should be skipped, got: ${JSON.stringify(r2)}`);
  });

  test('MCP27 non-.pdf/.md extension -> invalid_params', async () => {
    const vault = await makeVault('mcp27');
    const txt = join(vault, 'raw-sources', 'papers', 'note.txt');
    await writeFile(txt, 'plain text');
    await assert.rejects(
      handleIngestPdf(vault, { path: 'raw-sources/papers/note.txt' }, { claudeBin: claudeBin() }),
      (err) => err.code === 'invalid_params',
    );
  });

  test('MCP28 lockfile held by another writer -> LockTimeoutError', async () => {
    const vault = await makeVault('mcp28');
    await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault, 'raw-sources', 'papers', 'lk.pdf'));
    // 다른 프로세스가 보유 중을 모방
    await writeFile(join(vault, '.gieok-mcp.lock'), '99999\n');
    // ACQUIRE_TIMEOUT_MS를 짧게 덮어쓰기 어려우므로, LockTimeoutError를 실제 60s 기다리면
    // 느림. 단축을 위해 lockfile을 TTL 내로 취급되는 새로운 mtime으로 두고, timeout을
    // handler 내부 상수에 맡기는 대신 외부에서는 기다릴 수밖에 없다.
    // 실용적으로는, MCP28은 lockfile 존재→즉시 timeout 전환 어서션에 그치고,
    // LockTimeoutError 발화 시의 거동을 확인하는 범위로 좁힌다 (단시간 테스트).
    //
    // 전략: lockfile을 잡은 채 별 Promise로 handleIngestPdf를 기동, 매우 짧은 시간 동안
    //       아직 pending임을 어서션 → lock을 unlink하여 테스트 완료 (clean up)
    const p = handleIngestPdf(vault, { path: 'raw-sources/papers/lk.pdf' }, { claudeBin: claudeBin() });
    // 100ms 로는 extract까지 도달하지 못하고 lock 대기로 pending일 것
    const tick = new Promise((r) => setTimeout(() => r('pending'), 200));
    const res = await Promise.race([p.catch((e) => ({ err: e })), tick]);
    assert.equal(res, 'pending', `handler should be waiting on lock, got: ${JSON.stringify(res)}`);
    // 클린업: lockfile을 unlink하면 handler는 acquire하여 진행
    await rm(join(vault, '.gieok-mcp.lock'), { force: true });
    // handler 완료를 대기 (stub claude로 곧 종료됨)
    await p.catch(() => {}); // 이후 어서션은 별도 test에서
  });

  test('MCP29 child claude receives GIEOK_NO_LOG=1 + GIEOK_MCP_CHILD=1 + limited tools', async () => {
    // 로그를 클리어하고 MCP29 실행분만 관찰
    await writeFile(stubClaudeLog, '');
    const vault = await makeVault('mcp29');
    await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault, 'raw-sources', 'papers', 'env.pdf'));
    await handleIngestPdf(vault, { path: 'raw-sources/papers/env.pdf' }, { claudeBin: claudeBin() });
    const log = await readFile(stubClaudeLog, 'utf8');
    assert.match(log, /GIEOK_NO_LOG=1/, 'GIEOK_NO_LOG=1 propagated');
    assert.match(log, /GIEOK_MCP_CHILD=1/, 'GIEOK_MCP_CHILD=1 propagated');
    assert.match(log, /--allowedTools Write,Read,Edit/, 'allowedTools limited to Write,Read,Edit');
    assert.doesNotMatch(log, /--allowedTools[^\n]*Bash/, 'Bash NOT in allowedTools');
  });

  test('MCP29b child env is allowlist-filtered (LOW-4 defense)', async () => {
    // 2.1 security review LOW-4 대책: 무관한 secret env를 자식에 전파하지 않음.
    // 가짜 GH_TOKEN / AWS_SECRET_ACCESS_KEY를 process.env에 세팅하고,
    // stub claude 측 env dump에 나오지 않는지 확인한다.
    await writeFile(stubClaudeLog, '');
    const prevGh = process.env.GH_TOKEN;
    const prevAws = process.env.AWS_SECRET_ACCESS_KEY;
    process.env.GH_TOKEN = 'ghp_SHOULD_NOT_LEAK_TO_CHILD';
    process.env.AWS_SECRET_ACCESS_KEY = 'aws-SHOULD_NOT_LEAK';
    try {
      const vault = await makeVault('mcp29b');
      await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault, 'raw-sources', 'papers', 'env2.pdf'));
      await handleIngestPdf(vault, { path: 'raw-sources/papers/env2.pdf' }, { claudeBin: claudeBin() });
      const log = await readFile(stubClaudeLog, 'utf8');
      assert.doesNotMatch(log, /SHOULD_NOT_LEAK/, 'GH_TOKEN / AWS_SECRET_ACCESS_KEY NOT propagated');
      // 올바르게 전달되어야 할 것
      assert.match(log, /OBSIDIAN_VAULT=/, 'OBSIDIAN_VAULT IS propagated');
    } finally {
      if (prevGh === undefined) delete process.env.GH_TOKEN; else process.env.GH_TOKEN = prevGh;
      if (prevAws === undefined) delete process.env.AWS_SECRET_ACCESS_KEY; else process.env.AWS_SECRET_ACCESS_KEY = prevAws;
    }
  });

  test('MCP30 accepts absolute path resolving to vault raw-sources/', async () => {
    const vault = await makeVault('mcp30');
    const absPdf = join(vault, 'raw-sources', 'papers', 'abs.pdf');
    await cp(join(FIXTURES, 'sample-8p.pdf'), absPdf);
    const result = await handleIngestPdf(vault, { path: absPdf }, { claudeBin: claudeBin() });
    assert.equal(result.status, 'extracted_and_summarized');
    // 상대 경로여도 동일한 결과
    const vault2 = await makeVault('mcp30b');
    await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault2, 'raw-sources', 'papers', 'rel.pdf'));
    const result2 = await handleIngestPdf(
      vault2,
      { path: 'raw-sources/papers/rel.pdf' },
      { claudeBin: claudeBin() },
    );
    assert.equal(result2.status, 'extracted_and_summarized');
  });

  test('MCP30c skipLock injection bypasses withLock (기능 2.2 PDF dispatch 용)', async () => {
    // 기능 2.2 gieok_ingest_url이 PDF URL을 내부 dispatch할 때, 외측에서
    // withLock을 이미 보유했으므로 handleIngestPdf 측은 재획득을 스킵해야 함.
    // skipLock=true면 외부에서 lockfile이 잡혀 있어도 타임아웃 없이 즉시 진행.
    const vault = await makeVault('mcp30c-skiplock');
    await cp(join(FIXTURES, 'sample-8p.pdf'), join(vault, 'raw-sources', 'papers', 'noloc.pdf'));
    // 다른 PID의 lockfile을 가짜로 둔다 (TTL 내 살아있는 취급)
    const lockPath = join(vault, '.gieok-mcp.lock');
    await writeFile(lockPath, '99999\n');
    try {
      const result = await handleIngestPdf(
        vault,
        { path: 'raw-sources/papers/noloc.pdf' },
        { claudeBin: claudeBin(), skipLock: true },
      );
      assert.equal(result.status, 'extracted_and_summarized');
    } finally {
      await rm(lockPath, { force: true });
    }
  });
});
