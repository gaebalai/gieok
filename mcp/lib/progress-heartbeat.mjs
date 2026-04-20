// progress-heartbeat.mjs — 장시간 처리 중의 MCP progress notification 헬퍼
//
// 2026-04-20 v0.3.4: Claude Desktop 등의 MCP client 가 tool call 에 대해
// 기본 60 초로 request timeout 을 끊는 문제에 대한 대응. client 가 `_meta.progressToken`
// 을 보내온 경우, 그 token 에 대해 주기적으로 `notifications/progress` 를
// 되돌려 보냄으로써 client 측의 idle timeout 을 리셋하고, 실제 처리가 완주할 때까지
// 대기하도록 한다.
//
// 사용법:
//   const stop = startHeartbeat(sendProgress, 'ingesting PDF');
//   try {
//     await longRunningWork();
//   } finally {
//     await stop();  // 정지 + 최종 progress 를 전송
//   }
//
// - sendProgress 가 null/undefined (client 가 progressToken 을 보내지 않은 경우)
//   인 경우는 아무것도 하지 않고 no-op stop() 을 반환. handler 측은 분기 불필요.
// - 기본 간격 15 초 (Desktop 의 60s timeout 을 4 회 리셋하는 계산, safety margin 큼)
// - stopMessage 로 "XXX 완료" 등의 최종 progress 를 전송 가능

const DEFAULT_INTERVAL_MS = 15_000;

/**
 * @param {((msg?: string) => Promise<void>) | null | undefined} sendProgress
 *   server.mjs wrap 이 injection 경유로 넘기는 함수 (없으면 no-op).
 * @param {string} [initialMessage] - 하트비트 시작 시에 1 회 전송하는 메시지.
 * @param {object} [opts]
 * @param {number} [opts.intervalMs] - 전송 간격 (ms), 기본 15_000.
 * @returns {() => Promise<void>} stop 함수. interval clear + 최종 progress 전송.
 */
export function startHeartbeat(sendProgress, initialMessage, opts = {}) {
  // client 가 progressToken 을 보내지 않은 경우 sendProgress 는 null.
  // handler 측을 특별 취급하지 않도록 no-op stop 을 반환한다.
  if (typeof sendProgress !== 'function') {
    return async () => {};
  }
  const intervalMs = opts.intervalMs ?? DEFAULT_INTERVAL_MS;

  // sendProgress 의 동기 throw 도 reject 도 완전히 흡수하는 헬퍼.
  // client 측 단절 / transport error 등으로 interval 전체가 떨어지는 것을 방지.
  const safeSend = (msg) => {
    Promise.resolve()
      .then(() => sendProgress(msg))
      .catch(() => { /* ignore — 하트비트는 best-effort */ });
  };

  // 시작 시 즉시 1 회 전송 (progressToken 이 보이는 것을 확인하여 client 에 통지).
  if (initialMessage) safeSend(initialMessage);

  let stopped = false;
  const tickMessage = initialMessage ? `${initialMessage} (in progress)` : 'in progress';
  const timer = setInterval(() => {
    if (stopped) return;
    safeSend(tickMessage);
  }, intervalMs);

  return async (stopMessage) => {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
    if (stopMessage) {
      // 최종 progress 는 await 해서 client 에 반드시 전달한다 (stop 직후에 결과 JSON 을
      // 반환하는 경우, timing race 로 최종 progress 가 끊어질 가능성이 있으므로).
      try { await sendProgress(stopMessage); } catch { /* ignore */ }
    }
  };
}
