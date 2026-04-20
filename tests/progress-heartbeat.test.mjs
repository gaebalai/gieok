// progress-heartbeat.test.mjs — MCP progress notification 송신 로직
//
// v0.3.4 fix: 장시간 tool (gieok_ingest_pdf / gieok_ingest_url)에서 Claude Desktop이
// 60s request timeout을 끊는 문제의 수정. client의 progressToken에 대해 periodic하게
// notifications/progress를 보내 idle timeout을 리셋하는 기구.

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { startHeartbeat } from '../mcp/lib/progress-heartbeat.mjs';

describe('progress-heartbeat', () => {
  test('HB1 sendProgress=null → no-op, stop도 즉시 resolve', async () => {
    const stop = startHeartbeat(null, 'msg');
    assert.equal(typeof stop, 'function');
    await stop('final');
    // 예외 없이 완료되면 OK
  });

  test('HB2 sendProgress=undefined → no-op', async () => {
    const stop = startHeartbeat(undefined, 'msg');
    await stop();
  });

  test('HB3 initial message가 즉시 1회 송신됨', async () => {
    const calls = [];
    const fakeSend = async (msg) => { calls.push(msg); };
    const stop = startHeartbeat(fakeSend, 'initial');
    // startHeartbeat는 동기로 initial을 호출 (await 안 함)하지만, fakeSend는 즉시 반환
    // 되므로 다음 마이크로태스크에서 calls가 채워진다
    await new Promise((r) => setImmediate(r));
    assert.ok(calls.includes('initial'), `initial이 송신될 것 (got: ${JSON.stringify(calls)})`);
    await stop();
  });

  test('HB4 interval마다 periodic하게 송신됨', async () => {
    const calls = [];
    const fakeSend = async (msg) => { calls.push(msg); };
    // 고속화를 위해 intervalMs를 20ms로. initial 1회 + 20ms 2회 + stop 1회 = 4회 예상
    const stop = startHeartbeat(fakeSend, 'tick', { intervalMs: 20 });
    await new Promise((r) => setTimeout(r, 55));
    await stop('done');
    // initial + interval 2회 + stop
    assert.ok(calls.length >= 3, `최소 3회 호출됨 (got: ${calls.length}, calls: ${JSON.stringify(calls)})`);
    assert.equal(calls[0], 'tick', 'initial message');
    assert.ok(calls.some((m) => m === 'tick (in progress)'), 'interval tick');
    assert.equal(calls[calls.length - 1], 'done', 'final stop message');
  });

  test('HB5 stop() 이후에는 interval이 돌지 않음 (leak 방지)', async () => {
    const calls = [];
    const fakeSend = async (msg) => { calls.push(msg); };
    const stop = startHeartbeat(fakeSend, 'tick', { intervalMs: 20 });
    await new Promise((r) => setTimeout(r, 25));
    await stop('done');
    const afterStopCount = calls.length;
    // 추가로 60ms 기다려도 증가하지 않음
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(calls.length, afterStopCount,
      `stop 이후에도 heartbeat가 계속됨 (before: ${afterStopCount}, after: ${calls.length})`);
  });

  test('HB6 sendProgress가 throw해도 interval은 계속됨 (resilience)', async () => {
    let count = 0;
    const fakeSend = async () => {
      count++;
      throw new Error('send failed');
    };
    const stop = startHeartbeat(fakeSend, 'tick', { intervalMs: 15 });
    // interval을 2회 돌린다
    await new Promise((r) => setTimeout(r, 50));
    await stop('done');
    // initial + 최소 1회 interval + stop = 3회 이상 호출될 것
    assert.ok(count >= 3, `resilient (got: ${count})`);
  });

  test('HB7 stop()을 2회 호출해도 안전 (멱등)', async () => {
    const calls = [];
    const fakeSend = async (msg) => { calls.push(msg); };
    const stop = startHeartbeat(fakeSend, 'tick');
    await stop('done-1');
    await stop('done-2');
    const doneCount = calls.filter((m) => m.startsWith('done')).length;
    assert.equal(doneCount, 1, `stop-message는 1회만 송신됨 (got: ${calls.join(',')})`);
  });
});
