#!/usr/bin/env node
// session-logger.mjs — claude-brain 훅 본체
//
// Claude Code의 훅 이벤트를 stdin JSON으로 받아 1 세션 = 1 Markdown
// 파일로 $OBSIDIAN_VAULT/session-logs/ 에 추가한다.
// Node 18+ 내장 모듈만 사용. 외부 네트워크 금지.
// 에러 시에도 항상 exit 0 (Claude Code를 차단하지 않는 페일세이프).

import { appendFile, mkdir, readFile, writeFile, rename, open, stat, realpath } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { hostname } from 'node:os';

import { MASK_RULES } from '../scripts/lib/masking.mjs';

// -----------------------------------------------------------------------------
// 상수
// -----------------------------------------------------------------------------

const INDEX_VERSION = 1;
const MAX_STDOUT_CHARS = 2000;
const MAX_TITLE_CODEPOINTS = 50;

const BASH_BLOCKLIST = new Set([
  'ls', 'cat', 'head', 'tail', 'wc', 'file', 'stat', 'which', 'where', 'type',
  'echo', 'printf', 'pwd', 'cd', 'test', 'true', 'false', 'grep', 'rg', 'find',
  'diff', 'sort', 'uniq', 'tr', 'cut', 'mkdir', 'rmdir', 'rm', 'cp', 'mv', 'ln',
  'chmod', 'chown', 'touch', 'basename', 'dirname', 'realpath', 'readlink',
  'tree', 'du', 'df', 'less', 'more', 'xargs', 'tee', 'whoami', 'hostname',
  'date', 'uname', 'env', 'set', 'export', 'alias', 'id', 'jq',
]);

// 마스킹 규칙 (MASK_RULES)은 ../scripts/lib/masking.mjs 에 집약했다.
// 새 패턴 추가 시에는 그쪽 주석 (동기 대상 3곳)을 참조할 것.

// -----------------------------------------------------------------------------
// 유틸리티
// -----------------------------------------------------------------------------

function debugLog(ctx, msg) {
  if (process.env.GIEOK_DEBUG !== '1') return;
  process.stderr.write(`[claude-brain] ${msg}\n`);
  writeErrorLog(ctx, `DEBUG: ${msg}`).catch(() => {});
}

async function writeErrorLog(ctx, msg) {
  if (!ctx || !ctx.internalDir) return;
  try {
    await mkdir(ctx.internalDir, { recursive: true });
    const line = `[${new Date().toISOString()}] ${msg}\n`;
    await appendFile(join(ctx.internalDir, 'errors.log'), line, 'utf8');
  } catch {
    // 무시: 에러 로그 쓰기 실패는 묵살
  }
}

function mask(text) {
  if (typeof text !== 'string') return text;
  let out = text;
  for (const [re, rep] of MASK_RULES) {
    out = out.replace(re, rep);
  }
  return out;
}

// 로컬 타임존 기반 타임스탬프 생성 (OSS-001: Asia/Tokyo 하드코딩 폐지)
function localNow(date = new Date()) {
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  const YYYY = date.getFullYear();
  const MM = pad(date.getMonth() + 1);
  const DD = pad(date.getDate());
  const hh = pad(date.getHours());
  const mm = pad(date.getMinutes());
  const ss = pad(date.getSeconds());
  // 타임존 오프셋 계산 (getTimezoneOffset 은 UTC - local 을 분 단위로 반환)
  const tzOffset = -date.getTimezoneOffset();
  const tzSign = tzOffset >= 0 ? '+' : '-';
  const tzH = pad(Math.floor(Math.abs(tzOffset) / 60));
  const tzM = pad(Math.abs(tzOffset) % 60);
  const iso = `${YYYY}-${MM}-${DD}T${hh}:${mm}:${ss}${tzSign}${tzH}:${tzM}`;
  const compactDate = `${YYYY}${MM}${DD}`;
  const compactTime = `${hh}${mm}${ss}`;
  const clock = `${hh}:${mm}:${ss}`;
  return { iso, compactDate, compactTime, clock };
}

function sanitizeSidPrefix(sessionId) {
  const head = String(sessionId || '').slice(0, 4).toLowerCase();
  return head.replace(/[^a-z0-9]/g, '_') || '____';
}

// 프롬프트 문자열을 파일명용으로 새니타이즈한다
function sanitizeTitle(raw) {
  if (!raw || typeof raw !== 'string') return 'untitled';
  let s = raw;
  // 1. 제어 문자 → 공백
  s = s.replace(/[\x00-\x1f\x7f]/g, ' ');
  // 2. 경로 구분자 → -
  s = s.replace(/[/\\]/g, '-');
  // 3. Windows 예약 문자 → -
  s = s.replace(/[<>:"|?*]/g, '-');
  // 4. Unicode NFC 정규화
  s = s.normalize('NFC');
  // 5. 연속된 공백을 1개로, 공백을 -
  s = s.replace(/\s+/g, ' ').trim().replace(/ /g, '-');
  // 6. 앞뒤의 - 와 . 을 트림
  s = s.replace(/^[-.]+|[-.]+$/g, '');
  // 7. 최대 50 code point (surrogate safe)
  const codepoints = Array.from(s);
  if (codepoints.length > MAX_TITLE_CODEPOINTS) {
    s = codepoints.slice(0, MAX_TITLE_CODEPOINTS).join('');
    s = s.replace(/^[-.]+|[-.]+$/g, '');
  }
  return s || 'untitled';
}

function buildFileName({ compactDate, compactTime }, sessionId, title) {
  const sid4 = sanitizeSidPrefix(sessionId);
  return `${compactDate}-${compactTime}-${sid4}-${title}.md`;
}

// -----------------------------------------------------------------------------
// stdin 읽기
// -----------------------------------------------------------------------------

async function readStdin() {
  if (process.stdin.isTTY) return '';
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

// -----------------------------------------------------------------------------
// 인덱스 파일 관리
// -----------------------------------------------------------------------------

async function loadIndex(ctx) {
  try {
    const raw = await readFile(ctx.indexPath, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || typeof parsed.sessions !== 'object') {
      throw new Error('malformed index');
    }
    return parsed;
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      return { version: INDEX_VERSION, sessions: {} };
    }
    // 손상 → 대피
    try {
      const backup = `${ctx.indexPath}.broken-${Date.now()}`;
      await rename(ctx.indexPath, backup);
      await writeErrorLog(ctx, `WARN: index.json corrupted, moved to ${backup}`);
    } catch {
      /* ignore */
    }
    return { version: INDEX_VERSION, sessions: {} };
  }
}

async function saveIndex(ctx, index) {
  const tmp = `${ctx.indexPath}.tmp`;
  const payload = JSON.stringify(index, null, 2);
  await writeFile(tmp, payload, { encoding: 'utf8', mode: 0o600 });
  await rename(tmp, ctx.indexPath);
}

function newSessionEntry(fileName, isoDate, transcriptPath) {
  return {
    file: fileName,
    created: isoDate,
    first_prompt_saved: false,
    transcript_path: transcriptPath || null,
    transcript_read_offset: 0,
    counters: {
      user_prompts: 0,
      assistant_turns: 0,
      bash_commands_logged: 0,
      file_edits: 0,
    },
  };
}

// -----------------------------------------------------------------------------
// 세션 파일 해결 (인덱스 lookup + 신규 생성)
// -----------------------------------------------------------------------------

async function ensureSessionFile(ctx, index, payload, ts) {
  const sid = payload.session_id;
  const existing = index.sessions[sid];
  if (existing) {
    // transcript_path 가 나중에 도착하는 경우에 대비해 기록해 둔다
    if (!existing.transcript_path && payload.transcript_path) {
      existing.transcript_path = payload.transcript_path;
    }
    return existing;
  }

  // 신규 세션: 첫 이벤트가 UserPromptSubmit + prompt 가 아니면 생성하지 않는다.
  // 이를 통해 Claude Code의 서브에이전트 등이 발행하는 "사용자 발화를 수반하지 않는"
  // 유령 세션의 파일 생성을 막는다.
  if (payload.hook_event_name !== 'UserPromptSubmit' || !payload.prompt) {
    return null;
  }

  const title = sanitizeTitle(payload.prompt);
  const fileName = buildFileName(ts, sid, title);
  const entry = newSessionEntry(fileName, ts.iso, payload.transcript_path);
  entry.first_prompt_saved = true;
  index.sessions[sid] = entry;

  const filePath = join(ctx.sessionLogsDir, fileName);
  const fm = buildFrontmatter(payload, ts);
  await writeFile(filePath, fm, { encoding: 'utf8', mode: 0o600, flag: 'wx' });

  return entry;
}

function buildFrontmatter(payload, ts) {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || '';
  const lines = [
    '---',
    'type: session-log',
    `session_id: ${payload.session_id}`,
    `hostname: ${hostname()}`,
    `cwd: ${payload.cwd || ''}`,
    `date: ${ts.iso}`,
    `project_dir: ${projectDir || 'null'}`,
    'ingested: false',
    'related: []',
    '---',
    '',
  ];
  return lines.join('\n');
}

// -----------------------------------------------------------------------------
// 이벤트 핸들러
// -----------------------------------------------------------------------------

async function handleUserPromptSubmit(payload, ctx, index, entry, ts) {
  if (typeof payload.prompt !== 'string' || payload.prompt.length === 0) return;
  const masked = mask(payload.prompt);
  const body = `\n## User (${ts.clock})\n\n${masked}\n`;
  await appendFile(join(ctx.sessionLogsDir, entry.file), body, 'utf8');
  entry.counters.user_prompts += 1;
}

async function handleStop(payload, ctx, index, entry, ts) {
  // transcript_path 에서 차분 assistant 메시지를 추출
  const transcriptPath = payload.transcript_path || entry.transcript_path;
  if (!transcriptPath) {
    await writeErrorLog(ctx, `WARN: Stop without transcript_path (session=${payload.session_id})`);
    return;
  }
  entry.transcript_path = transcriptPath;

  let fileStat;
  try {
    fileStat = await stat(transcriptPath);
  } catch (err) {
    await writeErrorLog(ctx, `WARN: transcript not accessible: ${err.message}`);
    return;
  }

  let offset = Number(entry.transcript_read_offset || 0);
  if (offset > fileStat.size) {
    // rotate / truncate 감지 → 처음부터 다시 읽기
    offset = 0;
  }

  let chunk = '';
  try {
    const fh = await open(transcriptPath, 'r');
    try {
      const toRead = fileStat.size - offset;
      if (toRead <= 0) return;
      const buf = Buffer.alloc(toRead);
      await fh.read(buf, 0, toRead, offset);
      chunk = buf.toString('utf8');
    } finally {
      await fh.close();
    }
  } catch (err) {
    await writeErrorLog(ctx, `WARN: transcript read failed: ${err.message}`);
    return;
  }

  // 완결된 줄만 처리. 끝이 개행으로 끝나지 않는 경우 마지막 줄은 보류
  const endsWithNewline = chunk.endsWith('\n');
  const lines = chunk.split('\n');
  const consumedLines = endsWithNewline ? lines.slice(0, -1) : lines.slice(0, -1);
  const tail = endsWithNewline ? '' : lines[lines.length - 1];

  const consumedBytes = Buffer.byteLength(
    consumedLines.join('\n') + (consumedLines.length > 0 ? '\n' : ''),
    'utf8',
  );
  const newOffset = offset + consumedBytes;

  // assistant 텍스트를 추출
  const assistantTexts = [];
  for (const line of consumedLines) {
    if (!line) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (!obj || obj.type !== 'assistant') continue;
    const content = obj.message && obj.message.content;
    if (!Array.isArray(content)) continue;
    const textParts = content
      .filter((c) => c && c.type === 'text' && typeof c.text === 'string')
      .map((c) => c.text);
    if (textParts.length === 0) continue;
    assistantTexts.push(textParts.join(''));
  }

  entry.transcript_read_offset = newOffset;

  if (assistantTexts.length === 0) {
    // 모든 assistant 행이 thinking/tool_use 뿐이었던 경우 → 아무것도 쓰지 않는다
    // (단, 스키마 불일치 감지를 위해 어떤 형태로든 assistant 행은 있었을 것)
    return;
  }

  const combined = assistantTexts.join('\n\n');
  const masked = mask(combined);
  const body = `\n## Assistant (${ts.clock})\n\n${masked}\n`;
  await appendFile(join(ctx.sessionLogsDir, entry.file), body, 'utf8');
  entry.counters.assistant_turns += 1;
  void tail;
}

function splitBashCommand(cmd) {
  // ; && || | 로 분할 (엄밀하지는 않지만 간이적으로 충분)
  const segments = cmd.split(/(?:;|&&|\|\||\|)/);
  return segments.map((s) => s.trim()).filter(Boolean);
}

function firstWord(segment) {
  const m = segment.match(/^\s*([^\s]+)/);
  if (!m) return '';
  // 환경 변수 할당 (FOO=bar cmd)은 건너뛰고 다음 단어로
  if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(m[1])) {
    const rest = segment.replace(/^\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s*/, '');
    return firstWord(rest);
  }
  return m[1];
}

function isAllBlocked(cmd) {
  const segments = splitBashCommand(cmd);
  if (segments.length === 0) return true;
  for (const seg of segments) {
    const word = firstWord(seg);
    if (!BASH_BLOCKLIST.has(word)) return false;
  }
  return true;
}

function truncate(s, n) {
  if (typeof s !== 'string') return '';
  if (s.length <= n) return s;
  return s.slice(0, n) + ' ... (truncated)';
}

function quoteCallout(text) {
  return text
    .split('\n')
    .map((l) => `> ${l}`)
    .join('\n');
}

async function handlePostToolUse(payload, ctx, index, entry, ts) {
  const toolName = payload.tool_name;
  const input = payload.tool_input || {};
  const response = payload.tool_response || {};

  if (toolName === 'Bash') {
    const cmd = input.command;
    if (typeof cmd !== 'string' || cmd.length === 0) return;
    if (isAllBlocked(cmd)) return;

    const maskedCmd = mask(cmd);
    const stdout = mask(truncate(response.stdout || '', MAX_STDOUT_CHARS));

    const parts = [
      '',
      `> [!terminal]- Bash (${ts.clock})`,
      '> ```bash',
      ...maskedCmd.split('\n').map((l) => `> ${l}`),
      '> ```',
    ];
    if (stdout) {
      parts.push(quoteCallout(stdout));
    }
    parts.push('');
    await appendFile(join(ctx.sessionLogsDir, entry.file), parts.join('\n'), 'utf8');
    entry.counters.bash_commands_logged += 1;
    return;
  }

  if (toolName === 'Edit' || toolName === 'Write') {
    const filePath = input.file_path || '';
    const body = `\n> [!file] ${toolName}: ${filePath} (${ts.clock})\n`;
    await appendFile(join(ctx.sessionLogsDir, entry.file), body, 'utf8');
    entry.counters.file_edits += 1;
    return;
  }

  if (toolName === 'MultiEdit') {
    const filePath = input.file_path || '';
    const n = Array.isArray(input.edits) ? input.edits.length : 0;
    const body = `\n> [!file] MultiEdit: ${filePath} (${ts.clock}) — ${n} edits\n`;
    await appendFile(join(ctx.sessionLogsDir, entry.file), body, 'utf8');
    entry.counters.file_edits += 1;
    return;
  }
  // 그 외의 도구는 기록하지 않는다
}

async function handleSessionEnd(payload, ctx, index, entry, ts) {
  const c = entry.counters;
  const exitReason = payload.exit_reason || 'unknown';
  const body = [
    '',
    '---',
    '',
    `## Session Summary (${ts.clock})`,
    '',
    `- exit_reason: ${exitReason}`,
    `- user_prompts: ${c.user_prompts}`,
    `- assistant_turns: ${c.assistant_turns}`,
    `- bash_commands_logged: ${c.bash_commands_logged}`,
    `- file_edits: ${c.file_edits}`,
    '',
  ].join('\n');
  await appendFile(join(ctx.sessionLogsDir, entry.file), body, 'utf8');
}

const HANDLERS = {
  UserPromptSubmit: handleUserPromptSubmit,
  Stop: handleStop,
  PostToolUse: handlePostToolUse,
  SessionEnd: handleSessionEnd,
  // SessionStart: 향후 추가할 경우 여기에 1줄
};

// -----------------------------------------------------------------------------
// 메인
// -----------------------------------------------------------------------------

async function main() {
  // GIEOK_NO_LOG=1 일 때는 훅 전체를 no-op 화한다.
  // auto-ingest.sh / auto-lint.sh 가 기동하는 claude -p 서브프로세스는
  // 부모의 ~/.claude/settings.json 을 상속하므로 이 플래그가 없으면
  // 서브프로세스 자신의 활동이 session-logs/ 에 재귀적으로 기록되어 버린다.
  if (process.env.GIEOK_NO_LOG === '1') return;

  const vault = process.env.OBSIDIAN_VAULT;
  if (!vault) return;

  // VULN-003 + OSS-011: cwd 가 Vault 내부인 경우에도 no-op 화 (symlink 도 해결해서 비교)
  try {
    const realVault = await realpath(vault);
    const realCwd = await realpath(process.cwd());
    if (realCwd === realVault || realCwd.startsWith(realVault + '/')) return;
  } catch {
    // realpath 실패 시 폴백 (vault 가 존재하지 않는 등)
    const cwd = process.cwd();
    if (cwd === vault || cwd.startsWith(vault + '/')) return;
  }

  try {
    const s = await stat(vault);
    if (!s.isDirectory()) return;
  } catch {
    return;
  }

  const sessionLogsDir = join(vault, 'session-logs');
  const internalDir = join(sessionLogsDir, '.claude-brain');
  const indexPath = join(internalDir, 'index.json');
  const ctx = { vault, sessionLogsDir, internalDir, indexPath };

  let payload;
  try {
    const raw = await readStdin();
    if (!raw.trim()) return;
    payload = JSON.parse(raw);
  } catch {
    return;
  }

  if (!payload || typeof payload !== 'object') return;
  if (!payload.session_id || !payload.hook_event_name) return;

  const handler = HANDLERS[payload.hook_event_name];
  if (!handler) return;

  try {
    await mkdir(sessionLogsDir, { recursive: true, mode: 0o700 });
    await mkdir(internalDir, { recursive: true, mode: 0o700 });
  } catch (err) {
    await writeErrorLog(ctx, `ERROR: mkdir failed: ${err.message}`);
    return;
  }

  const ts = localNow();
  const index = await loadIndex(ctx);

  let entry;
  try {
    entry = await ensureSessionFile(ctx, index, payload, ts);
    if (!entry) {
      // 신규 세션에서 UserPromptSubmit 이외의 이벤트가 먼저 온 케이스 (ghost).
      // 파일도 index 도 건드리지 않고 종료한다.
      debugLog(ctx, `skipped ghost ${payload.hook_event_name} session=${payload.session_id.slice(0, 8)}`);
      return;
    }
    await handler(payload, ctx, index, entry, ts);
  } catch (err) {
    await writeErrorLog(ctx, `ERROR: handler failed (${payload.hook_event_name}): ${err.message}`);
    return;
  }

  try {
    await saveIndex(ctx, index);
  } catch (err) {
    await writeErrorLog(ctx, `ERROR: saveIndex failed: ${err.message}`);
  }

  debugLog(ctx, `handled ${payload.hook_event_name} session=${payload.session_id.slice(0, 8)}`);
}

process.on('unhandledRejection', (err) => {
  process.stderr.write(`[claude-brain] unhandledRejection: ${err && err.message}\n`);
  process.exit(0);
});

main().then(
  () => process.exit(0),
  () => process.exit(0),
);
