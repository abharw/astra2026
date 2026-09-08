import assert from "node:assert/strict";
import test from "node:test";
import { WebSocket } from "ws";
import { ModelTransport } from "../src/astra/client.js";
import { SessionServer } from "../src/server.js";

const noModelCalls: ModelTransport = { async *stream() {} };

test("shutdown closes live WebSockets instead of waiting for client disconnect", async () => {
  const server = new SessionServer({ host: "127.0.0.1", port: 0, model: noModelCalls });
  await server.listen();
  const socket = new WebSocket(`${server.address().replace("http", "ws")}/session`);
  try {
    await once(socket, "open");
    const closeStartedAt = Date.now();
    const socketClosed = once(socket, "close");
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        server.close(),
        new Promise<never>((_, reject) => { timeout = setTimeout(() => reject(new Error("server shutdown timed out")), 2_000); })
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
    await socketClosed;
    assert.ok(Date.now() - closeStartedAt < 2_000);
  } finally {
    socket.terminate();
    await server.close();
  }
});

function once(socket: WebSocket, event: "open" | "close"): Promise<void> {
  return new Promise((resolve, reject) => {
    socket.once(event, () => resolve());
    socket.once("error", reject);
  });
}
