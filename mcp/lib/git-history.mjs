// git-history.mjs — Visualizer (Phase D α) 에서 Git 이력을 읽기 위한 read-only 추상화
//
// 사용 예:
//   const commits = await getFileHistory(vaultDir, { since: '2026-01-01', subPath: 'wiki/' });
//   const content = await getFileContentAtCommit(vaultDir, sha, 'wiki/index.md');
//
// Security / Trust boundary:
//   - 모든 호출은 **spawn('git', [...])** 로 argv 배열 전달 (shell injection 회피, GIEOK 기존 패턴 준수)
//   - vaultDir 은 cwd 로만 사용 (디렉터리 존재 확인은 호출 측 책임)
//   - 비 git repo / git 미설치 시 `null` 또는 빈 배열 반환 (fail-safe)
//   - 외부 네트워크 호출 일체 없음, git fetch/push 미사용 (read-only: log, show, rev-parse)
//   - stdout 은 size cap 으로 제한 (매우 큰 repo 대응, 현재 16 MiB 상한)
//
// 정전: plan/claude/26042402_visualizer-concept-sketch.md §View 1 / §View 2

import { spawn } from 'node:child_process';

const MAX_STDOUT_BYTES = 16 * 1024 * 1024; // 16 MiB
const GIT_CMD = 'git';

export class GitHistoryError extends Error {
  constructor(message, code = 'git_error') {
    super(message);
    this.name = 'GitHistoryError';
    this.code = code;
  }
}

// 내부: git 명령을 spawn 으로 실행해 stdout/stderr/code 반환
// args 는 반드시 배열 전달 (shell injection 회피)
async function runGit(cwd, args) {
  if (!Array.isArray(args) || args.some((a) => typeof a !== 'string')) {
    throw new GitHistoryError('git args must be array of strings', 'invalid_args');
  }
  return new Promise((resolve) => {
    const child = spawn(GIT_CMD, args, {
      cwd,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', LC_ALL: 'C' },
    });
    const stdoutChunks = [];
    const stderrChunks = [];
    let stdoutBytes = 0;
    let truncated = false;

    child.stdout.on('data', (chunk) => {
      if (stdoutBytes + chunk.length > MAX_STDOUT_BYTES) {
        truncated = true;
        const remaining = MAX_STDOUT_BYTES - stdoutBytes;
        if (remaining > 0) {
          stdoutChunks.push(chunk.subarray(0, remaining));
          stdoutBytes = MAX_STDOUT_BYTES;
        }
        child.kill('SIGTERM');
        return;
      }
      stdoutChunks.push(chunk);
      stdoutBytes += chunk.length;
    });
    child.stderr.on('data', (chunk) => stderrChunks.push(chunk));
    child.on('error', (err) => {
      // ENOENT (git 미설치) 등 — resolve 로 error 반환 (throw 하지 않음)
      resolve({ code: -1, stdout: '', stderr: err.message, truncated: false, error: err });
    });
    child.on('close', (code) => {
      resolve({
        code,
        stdout: Buffer.concat(stdoutChunks).toString('utf8'),
        stderr: Buffer.concat(stderrChunks).toString('utf8'),
        truncated,
      });
    });
  });
}

// vaultDir 이 git repo 인지 판정 (rev-parse --git-dir 로 저비용)
export async function isGitRepo(vaultDir) {
  if (typeof vaultDir !== 'string' || vaultDir.length === 0) return false;
  const res = await runGit(vaultDir, ['rev-parse', '--is-inside-work-tree']);
  if (res.code !== 0) return false;
  return res.stdout.trim() === 'true';
}

// since 는 ISO 8601 date (예: "2026-01-01") 또는 git 이 수용하는 임의 형식
// subPath 는 vault-relative (예: "wiki/" / "wiki/index.md"), 빈 값이면 전체
// maxCommits 는 안전 상한 (default 1000)
// 반환: [{ sha, shortSha, timestamp (ms since epoch), author, subject, files: [paths...] }]
// git 이 없거나 repo 가 아니면 빈 배열
export async function getFileHistory(vaultDir, options = {}) {
  if (!(await isGitRepo(vaultDir))) return [];
  const { since, subPath = '', maxCommits = 1000 } = options;
  if (typeof maxCommits !== 'number' || maxCommits < 1 || maxCommits > 100000) {
    throw new GitHistoryError('maxCommits out of range (1..100000)', 'invalid_args');
  }
  if (typeof subPath !== 'string') {
    throw new GitHistoryError('subPath must be string', 'invalid_args');
  }
  const args = [
    'log',
    '--name-only',
    '--no-decorate',
    '--no-merges',
    `--max-count=${maxCommits}`,
    // 구분자 sentinel 사용 (개행을 포함한 파일명도 견디도록 설계, 단
    // git 이 newline 을 포함한 경로를 다른 escape 로 출력하므로 완전하지 않음)
    '--format=COMMIT\x1f%H\x1f%h\x1f%ct\x1f%an\x1f%s',
  ];
  if (since) args.push(`--since=${since}`);
  args.push('--');
  if (subPath) args.push(subPath);

  const res = await runGit(vaultDir, args);
  if (res.code !== 0) return [];
  return parseGitLogOutput(res.stdout);
}

// 특정 commit 의 지정 파일 내용 취득, 없으면 null
export async function getFileContentAtCommit(vaultDir, sha, relPath) {
  if (typeof sha !== 'string' || !/^[0-9a-f]{4,40}$/.test(sha)) {
    throw new GitHistoryError('invalid sha format', 'invalid_args');
  }
  if (typeof relPath !== 'string' || relPath.length === 0) {
    throw new GitHistoryError('relPath must be non-empty string', 'invalid_args');
  }
  if (relPath.includes('\0') || relPath.length > 4096) {
    throw new GitHistoryError('invalid relPath', 'invalid_args');
  }
  const res = await runGit(vaultDir, ['show', `${sha}:${relPath}`]);
  if (res.code !== 0) {
    // 해당 commit 에 파일이 없는 정상 케이스 → null
    return null;
  }
  return res.stdout;
}

// 지정 commit 에서 wiki/ 하위 md 파일 목록 (path 만)
// 실제 tree 를 ls-tree 로 나열 (log 보다 확실)
export async function listFilesAtCommit(vaultDir, sha, { subPath = 'wiki/' } = {}) {
  if (typeof sha !== 'string' || !/^[0-9a-f]{4,40}$/.test(sha)) {
    throw new GitHistoryError('invalid sha format', 'invalid_args');
  }
  const args = ['ls-tree', '-r', '--name-only', sha];
  if (subPath) args.push('--', subPath);
  const res = await runGit(vaultDir, args);
  if (res.code !== 0) return [];
  return res.stdout.split('\n').filter((l) => l.length > 0);
}

// 내부 parser: git log 의 stdout 을 commit 배열로
// format: "COMMIT\x1f<sha>\x1f<short>\x1f<unixtime>\x1f<author>\x1f<subject>\n<file>\n<file>\n\nCOMMIT..."
export function parseGitLogOutput(stdout) {
  if (typeof stdout !== 'string' || stdout.length === 0) return [];
  const commits = [];
  const blocks = stdout.split('COMMIT\x1f').slice(1); // 선두는 빈 요소
  for (const block of blocks) {
    const lines = block.split('\n');
    const headerLine = lines[0];
    if (!headerLine) continue;
    const parts = headerLine.split('\x1f');
    if (parts.length < 5) continue;
    const [sha, shortSha, ctStr, author, subject] = parts;
    const ts = Number(ctStr);
    if (!Number.isFinite(ts)) continue;
    const files = lines.slice(1).filter((l) => l.length > 0);
    commits.push({
      sha,
      shortSha,
      timestamp: ts * 1000, // ms since epoch
      author,
      subject,
      files,
    });
  }
  return commits;
}
