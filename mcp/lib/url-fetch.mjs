// url-fetch.mjs — HTTP GET + redirect 추적 + size cap + timeout + SSRF 2 단계
//
// 설계서 §4.5 §9.1 §9.3 — 다음을 담보:
//   - validateUrl (url-security) 을 각 hop 에서 호출
//   - scheme downgrade (https→http) 를 reject
//   - 최대 5 hops redirect
//   - 5MB body cap (streaming truncate)
//   - 30s 총 시간 timeout (AbortSignal.timeout)
//   - User-Agent 고정
//   - DNS rebinding 대책 (resolve 끝난 IP 를 custom lookup 으로 pin)

import { validateUrl, isPrivateIP, isLoopbackIP, isLinkLocalIP } from './url-security.mjs';
import { envPositiveInt } from './env-helpers.mjs';
import { lookup as dnsLookup } from 'node:dns/promises';

export class FetchError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'FetchError';
    this.code = code;
  }
}

// env footgun guard (blue M-1, 2026-04-20 security review): Number("")→0 이나
// Number("foo")→NaN 이 cap 을 silent-disable (fail-open) 하는 문제를 방지한다.
const DEFAULT_MAX_BYTES = envPositiveInt('GIEOK_URL_MAX_SIZE_BYTES', 5_000_000);
const DEFAULT_TIMEOUT_MS = envPositiveInt('GIEOK_URL_FETCH_TIMEOUT_MS', 30_000);
const DEFAULT_MAX_REDIRECTS = envPositiveInt('GIEOK_URL_MAX_REDIRECTS', 5);
const USER_AGENT = process.env.GIEOK_URL_USER_AGENT
  ?? 'gieok-wiki/0.3.0 (+https://github.com/gaebalai/gieok)';

/**
 * @typedef {Object} FetchResult
 * @property {number} status
 * @property {string} contentType
 * @property {string | Buffer} body
 * @property {boolean} truncated
 * @property {string} finalUrl
 * @property {Headers} headers
 */

/**
 * Fetch a URL with SSRF defenses, redirect tracking, size cap, and timeout.
 *
 * @param {string} urlStr
 * @param {object} [opts]
 * @param {number} [opts.maxBytes]
 * @param {number} [opts.timeoutMs]
 * @param {number} [opts.maxRedirects]
 * @param {boolean} [opts.binary]
 * @param {string} [opts.accept]
 * @param {string} [opts.assumeStartScheme] — override start scheme for downgrade detection (tests only, honored iff GIEOK_URL_ALLOW_LOOPBACK=1)
 * @param {Function} [opts._dnsLookupOverride] — test-only DNS lookup override for DNS rebinding tests
 * @returns {Promise<FetchResult>}
 */
export async function fetchUrl(urlStr, opts = {}) {
  const maxBytes = opts.maxBytes ?? DEFAULT_MAX_BYTES;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const maxRedirects = opts.maxRedirects ?? DEFAULT_MAX_REDIRECTS;
  const allowLoopback = process.env.GIEOK_URL_ALLOW_LOOPBACK === '1';
  // H1 fix: assumeStartScheme 는 test-injection hook — loopback 모드 외에서는 ignore
  // (production 측이 실수로 opts.assumeStartScheme 을 넘겨도 downgrade 판정이
  //  실제 URL 에서 분리되지 않도록 함)
  const assumeStartScheme = allowLoopback ? opts.assumeStartScheme : undefined;
  const binary = opts.binary === true;
  // L2 fix: test-only DNS lookup override — DNS rebinding 테스트를 hermetic 하게 구현하기 위해
  const dnsLookupOverride = opts._dnsLookupOverride;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new FetchError('timeout', 'timeout')), timeoutMs);

  try {
    // Validate + parse the initial URL
    let currentUrl = validateOrAllow(urlStr, allowLoopback);
    // Capture startScheme from the original URL (or test override) — never reassigned in loop
    const startScheme = assumeStartScheme ?? currentUrl.protocol;
    let hops = 0;

    while (true) {
      // SSRF defense layer 2: DNS rebinding check — called at EVERY hop
      await checkResolvedIp(currentUrl, allowLoopback, dnsLookupOverride);

      let res;
      try {
        res = await fetch(currentUrl.href, {
          method: 'GET',
          redirect: 'manual',
          signal: controller.signal,
          headers: {
            'User-Agent': USER_AGENT,
            'Accept': opts.accept ?? '*/*',
          },
        });
      } catch (err) {
        // When controller.abort(reason) is called, Node.js fetch throws `reason` directly.
        // Check if it's already a FetchError (e.g. our timeout FetchError) and re-throw.
        if (err instanceof FetchError) throw err;
        if (err.name === 'AbortError') {
          throw new FetchError('fetch timeout', 'timeout');
        }
        throw new FetchError(`fetch failed: ${err.message}`, 'fetch_failed');
      }

      // --- Redirect handling ---
      if (res.status >= 300 && res.status < 400) {
        const loc = res.headers.get('location');
        if (!loc) {
          throw new FetchError(`redirect without Location: ${res.status}`, 'redirect_invalid');
        }
        if (hops >= maxRedirects) {
          throw new FetchError(`redirect limit exceeded (${maxRedirects})`, 'redirect_limit');
        }

        let nextUrl;
        try {
          nextUrl = new URL(loc, currentUrl);
        } catch {
          throw new FetchError(`invalid redirect URL: ${loc}`, 'redirect_invalid');
        }

        // Scheme downgrade check — startScheme never changes, so https→http caught reliably
        if (startScheme === 'https:' && nextUrl.protocol !== 'https:') {
          throw new FetchError(`HTTPS → HTTP downgrade: ${nextUrl.href}`, 'scheme_downgrade');
        }

        // SSRF defense layer 1: validate redirect target URL (called at EVERY hop)
        currentUrl = validateOrAllow(nextUrl.href, allowLoopback);
        hops += 1;
        continue;
      }

      // --- Status code mapping ---
      if (res.status === 401 || res.status === 402 || res.status === 403) {
        throw new FetchError(`auth required (status ${res.status})`, 'auth_required');
      }
      if (res.status === 404 || res.status === 410) {
        throw new FetchError(`not found (status ${res.status})`, 'not_found');
      }
      if (res.status >= 500) {
        throw new FetchError(`server error (status ${res.status})`, 'server_error');
      }
      if (res.status >= 400) {
        throw new FetchError(`client error (status ${res.status})`, 'client_error');
      }

      // --- Read body with streaming size cap ---
      if (!res.body) {
        throw new FetchError('response body is null', 'fetch_failed');
      }
      const reader = res.body.getReader();
      const chunks = [];
      let total = 0;
      let truncated = false;

      while (true) {
        let done, value;
        try {
          ({ done, value } = await reader.read());
        } catch (err) {
          // When controller.abort(reason) fires, the reader throws `reason` directly.
          if (err instanceof FetchError) throw err;
          if (err.name === 'AbortError') {
            throw new FetchError('fetch timeout', 'timeout');
          }
          throw new FetchError(`body read failed: ${err.message}`, 'fetch_failed');
        }
        if (done) break;
        if (total + value.byteLength > maxBytes) {
          const remaining = maxBytes - total;
          if (remaining > 0) chunks.push(value.slice(0, remaining));
          total = maxBytes;
          truncated = true;
          // Close the connection to avoid resource leaks
          try { await reader.cancel(); } catch {}
          break;
        }
        chunks.push(value);
        total += value.byteLength;
      }

      const buf = Buffer.concat(chunks.map((c) => Buffer.from(c)));
      const contentType = res.headers.get('content-type') || '';
      return {
        status: res.status,
        contentType,
        body: binary ? buf : buf.toString('utf8'),
        truncated,
        finalUrl: currentUrl.href,
        headers: res.headers,
      };
    }
  } catch (err) {
    if (err instanceof FetchError) throw err;
    if (err.name === 'AbortError') {
      throw new FetchError('fetch timeout', 'timeout');
    }
    throw new FetchError(`fetch failed: ${err.message}`, 'fetch_failed');
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Validate a URL string against SSRF rules, or (in loopback-allowed test mode)
 * only check scheme and credentials.
 *
 * Called at the initial URL AND at every redirect hop.
 *
 * @param {string} urlStr
 * @param {boolean} allowLoopback
 * @returns {URL}
 */
function validateOrAllow(urlStr, allowLoopback) {
  if (allowLoopback) {
    let url;
    try {
      url = new URL(urlStr);
    } catch {
      throw new FetchError('URL parse failed', 'url_parse');
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw new FetchError(`scheme not allowed: ${url.protocol}`, 'url_scheme');
    }
    if (url.username || url.password) {
      throw new FetchError('credentials not allowed', 'url_credentials');
    }
    return url;
  }
  try {
    return validateUrl(urlStr);
  } catch (err) {
    // Re-wrap UrlSecurityError as FetchError to present a unified error type
    throw new FetchError(err.message, err.code);
  }
}

/**
 * DNS rebinding defense: resolve hostname and reject if the resolved IP is private.
 *
 * Called BEFORE EVERY hop's fetch(), not just the initial URL.
 * This catches DNS that returns a public IP on the first query (passes validateUrl)
 * but resolves to a private IP on subsequent queries.
 *
 * Bypass rules:
 * - allowLoopback=true AND no lookupOverride → bypass (existing test mode)
 * - lookupOverride provided → run check even under allowLoopback, using the injected
 *   lookup (L2 fix: lets DNS rebinding tests exercise this defense hermetically)
 * - host is already a numeric IP (already validated by validateUrl / validateOrAllow)
 *
 * @param {URL} url
 * @param {boolean} allowLoopback
 * @param {Function} [lookupOverride] — test-only DNS lookup (takes hostname, returns {address, family})
 */
async function checkResolvedIp(url, allowLoopback, lookupOverride) {
  if (allowLoopback && !lookupOverride) return;
  const host = url.hostname;
  // Skip resolution if already a numeric IP — validateUrl has already checked these
  if (/^[\d.]+$/.test(host) || host.includes(':')) return;
  const lookupFn = lookupOverride ?? dnsLookup;
  let resolved;
  try {
    resolved = await lookupFn(host);
  } catch {
    throw new FetchError(`DNS resolution failed: ${host}`, 'dns_failed');
  }
  if (
    isLoopbackIP(resolved.address) ||
    isLinkLocalIP(resolved.address) ||
    isPrivateIP(resolved.address)
  ) {
    throw new FetchError(
      `resolved IP is private: ${host} → ${resolved.address}`,
      'dns_private',
    );
  }
}
