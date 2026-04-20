// detached-spawn.mjs — 부모 MCP 프로세스가 종료되어도 살아남는 자식 프로세스 기동 헬퍼
//
// v0.3.5 Option B (early return + detached claude -p) 용 기반.
// Claude Desktop 의 MCPB extension 호출은 MCP SDK 의 60s hardcoded timeout 으로
// 끊어지기 때문에 (LocalMcpManager.callTool 이 timeout option 을 넘기지 않음),
// 장시간 처리 (PDF 요약 1-3 분) 는 백그라운드에서 돌리고 MCP handler 는 조기 return 한다.
//
// 설계서: plan/claude/26042004_feature-v0-3-5-early-return-design.md §구현 상세
// 의사록: plan/claude/26042003_meeting_v0-3-5-option-b-decision.md
//
// 사용법:
//   const pid = await spawnDetached('claude', ['-p', prompt, ...], {
//     logFile: `${vault}/.cache/claude-summary-<key>.log`,
//     env: buildChildEnv({ GIEOK_NO_LOG: '1', GIEOK_MCP_CHILD: '1', OBSIDIAN_VAULT: vault }),
//     cwd: vault,
//   });
//
// 주의사항:
//   - detached: true + child.unref() 로 부모 event loop 에서 분리한다.
//     어느 한쪽만으로는 불충분 (detached 만으로는 부모 exit 시 자식도 종료되는 경우가 있고,
//     unref 만으로는 부모는 기다리지 않지만 자식이 부모와 같은 process group 에 있어 SIGHUP 을 받음).
//   - stdio: stdin 은 'ignore', stdout/stderr 는 logFile 로 redirect. parent 의
//     MCP stdio (JSON-RPC framing) 를 오염시키지 않는다.
//   - spawn 실패 (ENOENT / EACCES 등) 는 'error' event 로 비동기 통지된다.
//     setImmediate 로 1 tick 대기 후 error 유무를 판정한다.
//   - env 는 caller 측에서 buildChildEnv() 등으로 allowlist filter 완료 상태여야 한다.
//     미지정 시 process.env 가 그대로 전달됨 (default 는 caller 책임으로 명시 권장).

import { spawn } from 'node:child_process';
import { open, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

/**
 * 부모 프로세스에서 분리된 자식 프로세스를 기동한다.
 *
 * @param {string} cmd - 실행 커맨드 (절대 경로 권장)
 * @param {string[]} args - 커맨드 인자
 * @param {object} opts
 * @param {string} opts.logFile - stdout/stderr 의 redirect 대상 (절대 경로, append 모드)
 * @param {Record<string,string>} [opts.env] - 자식의 env (caller 측에서 allowlist filter 완료)
 * @param {string} [opts.cwd] - 자식의 cwd
 * @returns {Promise<number>} 자식의 PID
 * @throws {Error} logFile 경로 부정 / spawn 실패 (ENOENT / EACCES)
 */
export async function spawnDetached(cmd, args, opts = {}) {
  if (!opts.logFile || typeof opts.logFile !== 'string') {
    throw new Error('spawnDetached: opts.logFile (string) is required');
  }

  // logFile 의 부모 디렉터리를 생성 (0o700 권한). 이미 존재하면 스킵.
  await mkdir(dirname(opts.logFile), { recursive: true, mode: 0o700 });

  // 추가 모드로 연다. 여러 번 spawn 되어도 이전 로그를 보존한다.
  // 0o600: owner read/write 만 (secrets 가 로그에 섞였을 때의 보호).
  const logFile = await open(opts.logFile, 'a', 0o600);

  try {
    const child = spawn(cmd, args, {
      detached: true,
      stdio: ['ignore', logFile.fd, logFile.fd],
      env: opts.env ?? process.env,
      cwd: opts.cwd,
      shell: false,
    });

    // spawn 의 실패 (ENOENT / EACCES) 는 'error' event 로 비동기 통지된다.
    // setImmediate 로 1 tick 대기 후 error 를 관측한다. pid 가 붙어있지 않으면 실패 취급.
    const pid = await new Promise((resolve, reject) => {
      let settled = false;
      child.once('error', (err) => {
        if (settled) return;
        settled = true;
        reject(err);
      });
      setImmediate(() => {
        if (settled) return;
        if (!child.pid) {
          settled = true;
          reject(new Error(`spawnDetached: spawn failed, no pid for ${cmd}`));
          return;
        }
        settled = true;
        resolve(child.pid);
      });
    });

    // 부모 event loop 에서 분리 (이게 없으면 부모가 child 종료까지 기다림).
    // pid 가 확정된 후에 unref 하지 않으면, unref 된 child 에 대한 error event
    // 를 관측할 수 없을 가능성이 있다.
    child.unref();
    return pid;
  } finally {
    // 자식에 fd 를 dup 완료했으므로 부모측 FileHandle 은 close 해도 된다.
    await logFile.close();
  }
}
