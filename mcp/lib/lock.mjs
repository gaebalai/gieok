// lock.mjs — Vault 쓰기용 advisory lockfile.
// fs.open(.., 'wx') 을 사용한 배타 생성 + TTL stale 감지.
// auto-ingest.sh / write_wiki / delete 가 동시에 Vault 를 건드려도 손상되지 않음.
//
// v0.3.5 추가:
//   `.gieok-summary-<key>.lock` — detached claude -p 의 tracking 용 (배타가 아닌 관측용).
//   auto-ingest.sh 는 `.gieok-summary-*.lock` 을 무시하므로, `.gieok-mcp.lock` 와는
//   별도 경로로 운영된다. 상세: plan/claude/26042004_feature-v0-3-5-early-return-design.md

import { open, stat, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const DEFAULT_TTL_MS = 30_000;
const POLL_INTERVAL_MS = 100;
// 기능 2.1 (논점 β): auto-ingest.sh 가 최대 30 분 lockfile 을 보유할 가능성이 있으므로,
// 10 초 → 60 초로 연장. Desktop 으로부터의 write_note 는 60 초 대기해도 성공하지 못할 경우
// LockTimeoutError 을 throw 하여 클라이언트에 명시 통지한다.
const ACQUIRE_TIMEOUT_MS = 60_000;
const LOCK_FILENAME = '.gieok-mcp.lock';

export class LockTimeoutError extends Error {
  constructor(message = 'lock acquire timeout') {
    super(message);
    this.name = 'LockTimeoutError';
    this.code = 'lock_timeout';
  }
}

export async function withLock(vault, fn, opts = {}) {
  const ttlMs = opts.ttlMs ?? DEFAULT_TTL_MS;
  const timeoutMs = opts.timeoutMs ?? ACQUIRE_TIMEOUT_MS;
  const lockPath = join(vault, LOCK_FILENAME);
  const start = Date.now();
  let handle;

  while (true) {
    try {
      handle = await open(lockPath, 'wx', 0o600);
      await handle.writeFile(`${process.pid}\n${new Date().toISOString()}\n`);
      break;
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
      try {
        const st = await stat(lockPath);
        if (Date.now() - st.mtimeMs > ttlMs) {
          await unlink(lockPath).catch(() => {});
          continue;
        }
      } catch (statErr) {
        if (statErr.code !== 'ENOENT') throw statErr;
        continue;
      }
      if (Date.now() - start > timeoutMs) {
        throw new LockTimeoutError();
      }
      await sleep(POLL_INTERVAL_MS);
    }
  }

  try {
    return await fn();
  } finally {
    try { await handle.close(); } catch {}
    try { await unlink(lockPath); } catch {}
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Summary-specific lockfile (v0.3.5 Option B)
// ---------------------------------------------------------------------------
// detached claude -p 의 PID 와 시작 시각을 기록하기 위한 관측용 파일.
// 배타 목적이 아님 (auto-ingest.sh 는 `.gieok-summary-*.lock` 을 무시).
// 목적:
//   - 어느 PDF 가 현재 백그라운드에서 요약 중인지 운영자가 확인 가능 (cron 로그 / ls)
//   - 다음 MCP 호출에서 동일 PDF 에 대한 중복 spawn 을 피하기 위한 판정 재료
//   - claude -p 가 비정상 종료된 경우의 forensic 정보
// 키 규칙: `<subdirPrefix>--<stem>` (ingest-pdf.mjs 의 chunk 명명과 정합)
// TTL: 30 분 (claude -p 의 최대 실행시간 상정). auto-ingest 가 stale 을 주워 정리한다.

const SUMMARY_LOCK_PREFIX = '.gieok-summary-';
const SUMMARY_LOCK_SUFFIX = '.lock';

export function summaryLockPath(vault, key) {
  if (typeof key !== 'string' || !key.length) {
    throw new Error('summaryLockPath: key required');
  }
  return join(vault, `${SUMMARY_LOCK_PREFIX}${key}${SUMMARY_LOCK_SUFFIX}`);
}

/**
 * detached claude 의 PID 를 기록한다. 동일 key 에 대해 여러 번 호출된 경우는
 * 최신 PID / timestamp 로 덮어쓴다 (다음 read 시 오래된 정보를 반환하지 않도록).
 *
 * @param {string} vault - Vault root (절대 경로)
 * @param {string} key - `<subdirPrefix>--<stem>` 형식의 식별자
 * @param {number} pid - detached 자식 프로세스의 PID
 * @returns {Promise<string>} 써낸 lockfile 의 절대 경로
 */
export async function writeSummaryLock(vault, key, pid) {
  const lockPath = summaryLockPath(vault, key);
  const body = `${pid}\n${new Date().toISOString()}\n`;
  // mode 0o600 (owner r/w) — lockfile 은 secret 을 포함하지 않지만 Vault 기본값에 맞춤
  await writeFile(lockPath, body, { mode: 0o600 });
  return lockPath;
}
