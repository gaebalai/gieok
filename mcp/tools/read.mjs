// gieok_read — Wiki 페이지의 내용을 반환한다.
// vault/wiki/<path> 하위만, 크기 상한 256 KB.

import { open, stat } from 'node:fs/promises';
import { z } from 'zod';
import { assertInsideWiki } from '../lib/vault-path.mjs';

const MAX_BYTES = 256 * 1024;

export const READ_TOOL_DEF = {
  name: 'gieok_read',
  title: 'Read GIEOK wiki page',
  description:
    'Read a Markdown page from the GIEOK wiki. Path is relative to $OBSIDIAN_VAULT/wiki/. Files larger than 256KB are truncated.',
  inputShape: {
    path: z
      .string()
      .min(1)
      .max(512)
      .regex(/^[\p{L}\p{N}/._ -]+\.md$/u)
      .describe('Relative path under wiki/, e.g. "index.md" or "concepts/foo.md".'),
  },
};

export async function handleRead(vault, args) {
  const path = args?.path;
  if (typeof path !== 'string' || !path) {
    const e = new Error('path is required');
    e.code = 'invalid_params';
    throw e;
  }
  const abs = await assertInsideWiki(vault, path);
  let st;
  try {
    st = await stat(abs);
  } catch (err) {
    if (err.code === 'ENOENT') {
      const e = new Error('file not found');
      e.code = 'file_not_found';
      throw e;
    }
    throw err;
  }
  if (!st.isFile()) {
    const e = new Error('not a regular file');
    e.code = 'not_a_file';
    throw e;
  }
  const handle = await open(abs, 'r');
  try {
    const truncated = st.size > MAX_BYTES;
    const readBytes = truncated ? MAX_BYTES : st.size;
    const buf = Buffer.alloc(readBytes);
    await handle.read(buf, 0, readBytes, 0);
    return {
      contents: buf.toString('utf8'),
      truncated,
      byteSize: st.size,
    };
  } finally {
    await handle.close();
  }
}
