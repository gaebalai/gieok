#!/usr/bin/env node
// gieok-mcp — GIEOK local MCP server (stdio)
//
// 환경 변수:
//   OBSIDIAN_VAULT  Vault 루트 (필수)
//   GIEOK_DEBUG     "1"이면 stderr로 디버그 출력
//
// Claude Desktop / Claude Code가 서브 프로세스로 기동하는 것을 전제로 함.
// stdout은 JSON-RPC 전용이므로, 로그는 반드시 console.error 경유로만 쓸 것.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { READ_TOOL_DEF, handleRead } from './tools/read.mjs';
import { LIST_TOOL_DEF, handleList } from './tools/list.mjs';
import { SEARCH_TOOL_DEF, handleSearch } from './tools/search.mjs';
import { WRITE_NOTE_TOOL_DEF, handleWriteNote } from './tools/write-note.mjs';
import { WRITE_WIKI_TOOL_DEF, handleWriteWiki } from './tools/write-wiki.mjs';
import { DELETE_TOOL_DEF, handleDelete } from './tools/delete.mjs';
import { INGEST_PDF_TOOL_DEF, handleIngestPdf } from './tools/ingest-pdf.mjs';
import { INGEST_URL_TOOL_DEF, handleIngestUrl } from './tools/ingest-url.mjs';

const VAULT = process.env.OBSIDIAN_VAULT;
if (!VAULT) {
  process.stderr.write('[gieok-mcp] OBSIDIAN_VAULT is required.\n');
  process.exit(1);
}

const debug = (msg) => {
  if (process.env.GIEOK_DEBUG === '1') {
    process.stderr.write(`[gieok-mcp] ${msg}\n`);
  }
};

const server = new McpServer(
  { name: 'gieok-wiki', version: '0.1.0' },
  { capabilities: { tools: {} } },
);

// 2026-04-20 v0.3.4 MCP progress heartbeat (장시간 실행 tool의 timeout 대책):
//   Claude Desktop 등의 MCP client는 tool call에 대해 기본 60초로
//   timeout을 끊지만, gieok_ingest_pdf / gieok_ingest_url은 PDF fetch +
//   extract-pdf.sh + claude -p summarize의 합계로 3~5분이 걸릴 수 있다.
//   client가 send한 _meta.progressToken이 있으면, handler에
//   `sendProgress(message?)`를 injection으로 전달하여 주기적으로
//   `notifications/progress`를 보낼 수 있도록 한다. client 측 idle timeout이
//   progress 수신으로 리셋되어, 내부 처리가 완주할 때까지 대기된다.
//
//   progressToken이 없는 client (구 프로토콜 등)는 sendProgress를 호출하면
//   silent no-op하는 헬퍼를 반환하므로, handler 쪽에서 분기 불필요.
function buildSendProgress(extra) {
  const token = extra?._meta?.progressToken;
  if (token === undefined || token === null || extra?.sendNotification == null) {
    // progressToken이 없다 = client가 progress를 요구하지 않음 → no-op
    return null;
  }
  let counter = 0;
  return async (message) => {
    counter += 1;
    try {
      await extra.sendNotification({
        method: 'notifications/progress',
        params: {
          progressToken: token,
          progress: counter,
          message: typeof message === 'string' && message.length > 0
            ? message.slice(0, 200) // 긴 문장은 200 char로 truncate (오송신 방지)
            : undefined,
        },
      });
    } catch {
      // progress 송신 실패는 치명적이지 않음 (client 측 단절 등) — silent pass
    }
  };
}

function wrap(handler) {
  return async (args, extra) => {
    const sendProgress = buildSendProgress(extra);
    const injections = sendProgress ? { sendProgress } : {};
    try {
      const result = await handler(VAULT, args ?? {}, injections);
      return {
        content: [
          { type: 'text', text: JSON.stringify(result, null, 2) },
        ],
      };
    } catch (err) {
      const code = err.code ?? 'internal_error';
      const message = err.message ?? String(err);
      const payload = { error: { code, message } };
      if (err.data) payload.error.data = err.data;
      return {
        isError: true,
        content: [
          { type: 'text', text: JSON.stringify(payload, null, 2) },
        ],
      };
    }
  };
}

function register(toolDef, handler) {
  server.registerTool(
    toolDef.name,
    {
      title: toolDef.title,
      description: toolDef.description,
      inputSchema: toolDef.inputShape,
    },
    (args, extra) => wrap(handler)(args, extra),
  );
}

register(READ_TOOL_DEF, handleRead);
register(LIST_TOOL_DEF, handleList);
register(SEARCH_TOOL_DEF, handleSearch);
register(WRITE_NOTE_TOOL_DEF, handleWriteNote);
register(WRITE_WIKI_TOOL_DEF, handleWriteWiki);
register(DELETE_TOOL_DEF, handleDelete);
register(INGEST_PDF_TOOL_DEF, handleIngestPdf);
register(INGEST_URL_TOOL_DEF, handleIngestUrl);

// 치명적 에러에서도 프로세스를 살려두어 에러 응답이 가능하도록 한다
process.on('uncaughtException', (err) => {
  process.stderr.write(`[gieok-mcp] uncaughtException: ${err.stack ?? err.message}\n`);
});
process.on('unhandledRejection', (reason) => {
  process.stderr.write(`[gieok-mcp] unhandledRejection: ${reason?.stack ?? reason}\n`);
});

const transport = new StdioServerTransport();
await server.connect(transport);
debug('connected (stdio)');
