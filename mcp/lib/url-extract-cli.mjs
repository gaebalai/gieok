#!/usr/bin/env node
// url-extract-cli.mjs — shell / MCP 에서 spawn 되는 node CLI.
//
// 사용법:
//   node url-extract-cli.mjs --url <url> --vault <vault> --subdir <subdir>
//     [--refresh-days <n|never>]
//     [--title <s>] [--source-type <s>] [--tags <a,b,c>]
//     [--robots-override <url>]
//
// stdout: 성공 시 JSON (status, path, source_sha256, ...)
// stderr: 에러 (`Error (<code>): <message>`)
// exit code:
//   0  정상
//   2  인자 에러
//   3  robots.txt Disallow
//   4  fetch / extraction 실패
//   5  쓰기 / 기타 실패

import { extractAndSaveUrl } from './url-extract.mjs';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (!flag.startsWith('--')) continue;
    const key = flag.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

function parseRefreshDays(raw) {
  if (raw === undefined || raw === true) return undefined;
  if (raw === 'never') return 'never';
  const n = Number(raw);
  if (Number.isInteger(n) && n > 0) return n;
  // caller provides a bad value — let extractAndSaveUrl fall back to env default.
  return undefined;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.url || args.url === true) {
    process.stderr.write('Error: --url required\n');
    process.exit(2);
  }
  if (!args.vault || args.vault === true) {
    process.stderr.write('Error: --vault required\n');
    process.exit(2);
  }
  const refreshDays = parseRefreshDays(args['refresh-days']);
  const callOpts = {
    url: args.url,
    vault: args.vault,
    subdir: typeof args.subdir === 'string' ? args.subdir : 'articles',
    title: typeof args.title === 'string' ? args.title : undefined,
    sourceType: typeof args['source-type'] === 'string' ? args['source-type'] : undefined,
    tags: typeof args.tags === 'string'
      ? args.tags.split(',').map((t) => t.trim()).filter(Boolean)
      : [],
    robotsUrlOverride: typeof args['robots-override'] === 'string'
      ? args['robots-override']
      : undefined,
  };
  // refreshDays 는 has-own-property 로 gate 된다 (orchestrator 의 Deviation 2).
  // undefined 를 명시적으로 넘기면 hasOwnProperty 가 true 가 되어 early-return 이 engage 하여
  // UI9 smoke-test 를 망가뜨린다. 따라서 명시값이 있을 때만 속성 추가.
  if (refreshDays !== undefined) callOpts.refreshDays = refreshDays;
  try {
    const r = await extractAndSaveUrl(callOpts);
    process.stdout.write(JSON.stringify(r) + '\n');
    process.exit(0);
  } catch (err) {
    const code = err.code || 'unknown';
    // red M-2 fix (2026-04-20): err.message 에 내부 IP / 해결된 hostname /
    // attacker-controlled redirect URL 이 그대로 들어가는 경우 (예: FetchError(
    // 'resolved IP is private: evil.com → 10.0.0.5', 'dns_private')) 가
    // cron 측 로그에 leak 된다. MCP 경로는 mapFetchErrorAndThrow 로 scrub 완료되었지만,
    // cron → extract-url.sh → node CLI 경로는 생 메시지. code 만 출력하여
    // attacker-controlled 문자열의 로그 혼입을 방지.
    const securityCodes = new Set([
      'fetch_failed', 'timeout', 'dns_failed', 'dns_private',
      'auth_required', 'not_found', 'server_error', 'client_error',
      'redirect_invalid', 'redirect_limit', 'scheme_downgrade',
      'url_scheme', 'url_credentials', 'url_parse', 'url_private_ip',
      'url_loopback', 'url_link_local', 'url_metadata',
    ]);
    if (securityCodes.has(code)) {
      process.stderr.write(`Error (${code}): blocked by security policy\n`);
    } else {
      // not_html / extraction_failed / robots_disallow 등, 애플리케이션
      // 에러는 message 를 내도 OK (기본 msg 는 attacker-controlled 가 아님).
      process.stderr.write(`Error (${code}): ${err.message}\n`);
    }
    if (code === 'robots_disallow') process.exit(3);
    if (securityCodes.has(code) || code === 'extraction_failed' || code === 'not_html') {
      process.exit(4);
    }
    process.exit(5);
  }
}

main();
