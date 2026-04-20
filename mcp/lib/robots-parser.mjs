// robots-parser.mjs — robots.txt 최소한의 파서
//
// 사양 참고: https://datatracker.ietf.org/doc/html/rfc9309
// User-agent / Disallow / Allow 만 지원. Crawl-delay 등은 무시.

export function parseRobotsTxt(text) {
  const groups = [];
  let currentAgents = [];
  let currentRules = [];
  const lines = text.split(/\r?\n/);
  const flush = () => {
    if (currentAgents.length > 0) {
      groups.push({ agents: currentAgents, rules: currentRules });
    }
    currentAgents = [];
    currentRules = [];
  };
  let lastDirectiveWasAgent = false;
  for (let rawLine of lines) {
    const hashIdx = rawLine.indexOf('#');
    if (hashIdx !== -1) rawLine = rawLine.slice(0, hashIdx);
    const line = rawLine.trim();
    if (!line) continue;
    const colonIdx = line.indexOf(':');
    if (colonIdx === -1) continue;
    const directive = line.slice(0, colonIdx).trim().toLowerCase();
    const value = line.slice(colonIdx + 1).trim();
    if (directive === 'user-agent') {
      if (!lastDirectiveWasAgent && currentRules.length > 0) flush();
      currentAgents.push(value.toLowerCase());
      lastDirectiveWasAgent = true;
    } else if (directive === 'disallow') {
      currentRules.push({ type: 'disallow', path: value });
      lastDirectiveWasAgent = false;
    } else if (directive === 'allow') {
      currentRules.push({ type: 'allow', path: value });
      lastDirectiveWasAgent = false;
    }
  }
  flush();
  return { groups };
}

export function isAllowed(rules, userAgent, path) {
  const ua = userAgent.toLowerCase();
  const matching = rules.groups.filter((g) => g.agents.some((a) => a === ua));
  const wildcardGroups = rules.groups.filter((g) => g.agents.some((a) => a === '*'));
  const selectedGroups = matching.length > 0 ? matching : wildcardGroups;
  if (selectedGroups.length === 0) return true;
  const allRules = selectedGroups.flatMap((g) => g.rules);
  let best = null;
  for (const rule of allRules) {
    if (!rule.path) continue;
    if (pathMatches(path, rule.path)) {
      if (!best || rule.path.length > best.path.length ||
          (rule.path.length === best.path.length && rule.type === 'allow')) {
        best = rule;
      }
    }
  }
  if (!best) return true;
  return best.type === 'allow';
}

// blue M-4 fix (2026-04-20): RFC9309 / Google 사양의 `*` wildcard 와 `$`
// end-of-path anchor 를 지원. wildcard 미지원 시에는 `Disallow: /*.pdf$` 등이
// silent-allow 가 되어 fail-open 의 policy 일탈을 일으키고 있었다.
//
// 단순하게 pattern 을 정규 표현식으로 변환:
//   `*` → `.*`
//   말미의 `$` → `$` (end-of-path anchor)
//   그 외 정규 표현식 메타 문자 → 이스케이프
//
// 동작은 prefix match 의 superset 이므로 wildcard 를 포함하지 않는 기존 pattern 은
// 종전대로 prefix 일치한다.
function pathMatches(path, pattern) {
  if (!pattern.includes('*') && !pattern.endsWith('$')) {
    // fast path: 종전의 prefix match (기존 동작 유지)
    return path.startsWith(pattern);
  }
  try {
    let regexSrc = '^';
    let p = pattern;
    const hasEndAnchor = p.endsWith('$') && !p.endsWith('\\$');
    if (hasEndAnchor) p = p.slice(0, -1);
    for (const ch of p) {
      if (ch === '*') {
        regexSrc += '.*';
      } else {
        regexSrc += ch.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
      }
    }
    if (hasEndAnchor) regexSrc += '$';
    const re = new RegExp(regexSrc);
    return re.test(path);
  } catch {
    // 부정한 pattern (상정 외) 은 fail-closed: match 취급하여
    // 호출자 측에서 deny 쪽으로 기울인다. URL 을 때리기보다 보수적으로 skip 하는 쪽이 안전.
    return true;
  }
}
