// vault-path.mjs — Vault 경계의 realpath 가드.
// MCP 의 write/delete/read 에서 path traversal / symlink 탈출 / 절대 경로 지정을 차단한다.

import { realpath } from 'node:fs/promises';
import { isAbsolute, join, normalize, sep } from 'node:path';

// 한국어, 중국어, 일본어, 기타 Unicode Letter 를 허용한다 (write-note.mjs 의
// makeSlug 가 \p{L} 를 보존하는 것과 정합시키기 위해).
// \p{L} = Unicode Letter property, \p{N} = Number property.
// path traversal "." 과 경로 구분 "/" 는 명시적으로 허용 집합에 포함되어 있으며,
// realpath + prefix containment (resolveWithinBase 참조) 으로 escape 를 차단한다.
const SAFE_PATH_RE = /^[\p{L}\p{N}/._ -]+$/u;
const MAX_PATH_LEN = 512;

export class PathBoundaryError extends Error {
  constructor(message, code = 'path_outside_boundary') {
    super(message);
    this.name = 'PathBoundaryError';
    this.code = code;
  }
}

function validateRelative(rel) {
  if (typeof rel !== 'string' || rel.length === 0) {
    throw new PathBoundaryError('path must be a non-empty string', 'invalid_path');
  }
  if (rel.length > MAX_PATH_LEN) {
    throw new PathBoundaryError('path too long', 'invalid_path');
  }
  if (rel.includes('\0')) {
    throw new PathBoundaryError('path contains null byte', 'invalid_path');
  }
  if (isAbsolute(rel)) {
    throw new PathBoundaryError('path must be relative', 'absolute_path');
  }
  if (!SAFE_PATH_RE.test(rel)) {
    throw new PathBoundaryError('path contains unsafe characters', 'invalid_path');
  }
  const normalized = normalize(rel);
  if (normalized === '..' || normalized.startsWith('..' + sep) || normalized.includes(sep + '..' + sep)) {
    throw new PathBoundaryError('path escapes parent', 'path_traversal');
  }
}

async function realpathWithFallback(target) {
  try {
    return await realpath(target);
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    // 파일 미존재 시 (write 의 create 에서 정상). 부모를 거슬러 realpath 하고, 미존재 말미를 다시 결합한다.
    const tail = [];
    let cur = target;
    while (true) {
      const idx = cur.lastIndexOf(sep);
      if (idx <= 0) {
        throw new PathBoundaryError('path resolution failed (no existing ancestor)', 'invalid_path');
      }
      tail.unshift(cur.substring(idx + 1));
      cur = cur.substring(0, idx);
      try {
        const real = await realpath(cur);
        return join(real, ...tail);
      } catch (e) {
        if (e.code !== 'ENOENT') throw e;
      }
    }
  }
}

async function resolveWithinBase(vault, subdir, rel) {
  validateRelative(rel);
  let baseAbs;
  try {
    baseAbs = await realpath(join(vault, subdir));
  } catch (err) {
    throw new PathBoundaryError(`base directory not found: ${subdir}`, 'base_missing');
  }
  const candidate = join(baseAbs, rel);
  const resolved = await realpathWithFallback(candidate);
  if (resolved !== baseAbs && !resolved.startsWith(baseAbs + sep)) {
    throw new PathBoundaryError('path outside boundary', 'path_outside_boundary');
  }
  return resolved;
}

export async function assertInsideWiki(vault, rel) {
  return resolveWithinBase(vault, 'wiki', rel);
}

export async function assertInsideSessionLogs(vault, rel) {
  return resolveWithinBase(vault, 'session-logs', rel);
}

export async function assertInsideArchive(vault, rel) {
  return resolveWithinBase(vault, 'wiki/.archive', rel);
}

// 기능 2.1: gieok_ingest_pdf 용 raw-sources/ 경계 가드.
// 인자는 raw-sources/ 로부터의 상대가 아니라 Vault 로부터의 상대 경로로 받음
// (예: "raw-sources/papers/foo.pdf") 이므로 rel 에서 선두의 "raw-sources/" 를
// 제거한 후 resolveWithinBase 에 넘긴다.
export async function assertInsideRawSources(vault, rel) {
  if (typeof rel !== 'string' || !rel) {
    throw new PathBoundaryError('path must be a non-empty string', 'invalid_path');
  }
  const stripped = rel.startsWith('raw-sources/') ? rel.slice('raw-sources/'.length) : rel;
  return resolveWithinBase(vault, 'raw-sources', stripped);
}

// 기능 2.2: url-extract orchestrator 용의 raw-sources/<subdir>/ 경계 가드.
// subdir 는 고정의 안전한 디렉터리명 (articles/papers 등) 을 기대한다.
// path 구분자, 선두 dot, 빈 문자열을 걸러내고, 나머지는 resolveWithinBase 의 SAFE_PATH_RE 에 맡긴다.
export async function assertInsideRawSourcesSubdir(vault, subdir, rel) {
  if (typeof subdir !== 'string' || !subdir || subdir.includes('/') || subdir.includes(sep) || subdir.startsWith('.') || subdir.includes('\0')) {
    throw new PathBoundaryError('invalid subdir', 'invalid_path');
  }
  return resolveWithinBase(vault, `raw-sources/${subdir}`, rel);
}

// 2026-04-20 MED-b1 fix: 범용적인 vault-relative base 에 대한 경계 realpath 가드.
// `.cache/html/` 등, url-extract.mjs 가 urlToFilename sanitizer 에 의존하던
// 쓰기 대상에 대해 detective control (realpath containment check) 을 추가한다.
// urlToFilename 의 sanitizer 가 향후 완화되어도, 이 가드로 vault 내 경계를 강제한다.
//
// 전형적인 호출 예:
//   await assertInsideBase(vault, '.cache/html', htmlFilename);
//
// 단일 계층의 상대 기저 (dot-prefix 가능) 를 받는다. subdir 를 '.' 이나 path traversal 요소로
// 시작시키는 오용은 걸러낸다.
export async function assertInsideBase(vault, relBase, rel) {
  if (typeof relBase !== 'string' || !relBase) {
    throw new PathBoundaryError('relBase required', 'invalid_path');
  }
  // 상대 base 는 절대 경로나 null byte 를 거부. "/" / "\\" / ".." 세그먼트는 허용 (예:
  // ".cache/html", "wiki/.archive"). segment level 에서 ".." 금지를 확인한다.
  if (relBase.includes('\0') || isAbsolute(relBase)) {
    throw new PathBoundaryError('invalid relBase', 'invalid_path');
  }
  const segs = relBase.split('/').filter(Boolean);
  if (segs.length === 0 || segs.some((s) => s === '..')) {
    throw new PathBoundaryError('invalid relBase', 'invalid_path');
  }
  return resolveWithinBase(vault, relBase, rel);
}
