// tests/helpers/fixture-server.mjs — 로컬 HTTP 픽스처 서버
//
// port 0 으로 자동 채번, 테스트 내에서 기동 → URL 을 fetch → close 의 사용법.
// fixtures/html/ 하위의 정적 파일을 배포. `/robots.txt` 는 variant 쿼리로
// 교체 가능 (disallow/allow/mixed). `/redirect-target` 은 query 에서
// body 와 Content-Type 을 지정할 수 있다 (PDF dispatch 테스트용).

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, normalize } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '..', 'fixtures', 'html');

const CONTENT_TYPE_MAP = {
  '.html': 'text/html; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
};

// /html-then-pdf?name=<fixture> 용 카운터. 동일 URL 에 대해
// 1회차: 짧은 HTML 을 text/html 로, 2회차 이후: PDF 를 application/pdf 로 반환.
// CRIT-1 (late-PDF discovery: extractAndSaveUrl 의 2단계 fetch 가 PDF 를 당긴 경우) 의
// 회귀 테스트 (MCP46) 에서 사용. 테스트 간에 누출되지 않도록 server 인스턴스마다
// Map 을 다시 만든다.
/**
 * @param {object} [opts]
 * @returns {Promise<{url: string, port: number, close: () => void, requestLog: Array, htmlThenPdfCounts: Map}>}
 */
export async function startFixtureServer(opts = {}) {
  const requestLog = [];
  const htmlThenPdfCounts = new Map();
  const server = createServer(async (req, res) => {
    requestLog.push({ url: req.url, method: req.method, headers: { ...req.headers } });
    const url = new URL(req.url, 'http://localhost');
    const pathname = url.pathname;

    // /robots.txt with variant support
    if (pathname === '/robots.txt') {
      const variant = url.searchParams.get('variant') || 'allow';
      try {
        const body = await readFile(join(FIXTURE_DIR, `robots-${variant}.txt`), 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end(body);
      } catch {
        res.writeHead(404); res.end();
      }
      return;
    }

    // /redirect-target?ct=...&body=... — arbitrary response for dispatch tests
    if (pathname === '/redirect-target') {
      const ct = url.searchParams.get('ct') || 'text/plain';
      const body = url.searchParams.get('body') || '';
      res.writeHead(200, { 'Content-Type': ct });
      res.end(body);
      return;
    }

    // /redirect-to/<path> — issue 302 Location header
    if (pathname.startsWith('/redirect-to/')) {
      const target = decodeURIComponent(pathname.slice('/redirect-to/'.length));
      res.writeHead(302, { Location: target });
      res.end();
      return;
    }

    // /slow — slowloris simulation
    if (pathname === '/slow') {
      // Send no body, keep connection open
      setTimeout(() => { res.writeHead(200); res.end('done'); }, 60000);
      return;
    }

    // /status?code=401 — return arbitrary status code
    if (pathname === '/status') {
      const code = parseInt(url.searchParams.get('code') || '200', 10);
      res.writeHead(code, { 'Content-Type': 'text/html' });
      res.end(url.searchParams.get('body') || '');
      return;
    }

    // /huge — 10MB body
    if (pathname === '/huge') {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      const chunk = Buffer.alloc(1024 * 1024, 'a');
      for (let i = 0; i < 10; i++) res.write(chunk);
      res.end();
      return;
    }

    // /pdf?name=<fixture>&ct=<ct> — serve a PDF fixture from tests/fixtures/pdf/.
    // Used by ingest-url MCP tests to exercise PDF dispatch (기능 2.2 §4.7).
    if (pathname === '/pdf') {
      const name = url.searchParams.get('name') || 'sample-8p.pdf';
      const ct = url.searchParams.get('ct') || 'application/pdf';
      try {
        const pdfPath = join(__dirname, '..', 'fixtures', 'pdf', name);
        const body = await readFile(pdfPath);
        res.writeHead(200, { 'Content-Type': ct });
        res.end(body);
      } catch {
        res.writeHead(404); res.end();
      }
      return;
    }

    // /pdf-file/<name>.pdf?ct=<ct> — serve a PDF fixture with the URL pathname
    // ending in `.pdf`. Required for testing the "octet-stream + URL ends .pdf"
    // dispatch heuristic (MCP43); the /pdf?name= variant has `.pdf` only in the
    // query string and so does not match the pathname-suffix check.
    if (pathname.startsWith('/pdf-file/')) {
      const name = pathname.slice('/pdf-file/'.length);
      const ct = url.searchParams.get('ct') || 'application/pdf';
      try {
        const pdfPath = join(__dirname, '..', 'fixtures', 'pdf', name);
        const body = await readFile(pdfPath);
        res.writeHead(200, { 'Content-Type': ct });
        res.end(body);
      } catch {
        res.writeHead(404); res.end();
      }
      return;
    }

    // /html-then-pdf?name=<fixture> — return HTML on the first request and the
    // named PDF fixture on subsequent requests. Used by MCP46 to reproduce the
    // late-PDF discovery path: extractAndSaveUrl's first fetch sees text/html
    // (passes the outer Content-Type gate) but the orchestrator's own fetch
    // round-trips back as application/pdf, taking the err.code === 'not_html' +
    // pdfCandidate branch in ingest-url.mjs. The body must NOT be valid UTF-8
    // (we serve real PDF bytes) — that's the whole point of the regression.
    if (pathname === '/html-then-pdf') {
      const name = url.searchParams.get('name') || 'sample-8p.pdf';
      const key = `${pathname}?${name}`;
      const count = htmlThenPdfCounts.get(key) || 0;
      htmlThenPdfCounts.set(key, count + 1);
      if (count === 0) {
        // First call: short HTML. Sparse content forces extractAndSaveUrl past
        // the Content-Type 'not_html' early-exit and into its own fetchUrl call
        // (which returns the PDF bytes second time around).
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end('<!DOCTYPE html><html><head><title>flip</title></head><body><p>placeholder</p></body></html>');
        return;
      }
      try {
        const pdfPath = join(__dirname, '..', 'fixtures', 'pdf', name);
        const body = await readFile(pdfPath);
        res.writeHead(200, { 'Content-Type': 'application/pdf' });
        res.end(body);
      } catch {
        res.writeHead(404); res.end();
      }
      return;
    }

    // /huge-pdf — fake > 50MB PDF body (zeros) to exercise the size cap on PDF URLs.
    if (pathname === '/huge-pdf') {
      res.writeHead(200, { 'Content-Type': 'application/pdf' });
      const chunk = Buffer.alloc(1024 * 1024, 0);
      for (let i = 0; i < 55; i++) res.write(chunk);
      res.end();
      return;
    }

    // Static file from FIXTURE_DIR
    const safePath = normalize(pathname).replace(/^[./]+/, '');
    const filePath = join(FIXTURE_DIR, safePath);
    if (!filePath.startsWith(FIXTURE_DIR)) {
      res.writeHead(403); res.end(); return;
    }
    try {
      const body = await readFile(filePath);
      const ext = '.' + filePath.split('.').pop();
      res.writeHead(200, { 'Content-Type': CONTENT_TYPE_MAP[ext] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404); res.end();
    }
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    url: `http://127.0.0.1:${port}`,
    port,
    requestLog,
    htmlThenPdfCounts,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
