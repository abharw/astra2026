import { createServer, IncomingMessage, Server, ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { WebSocket, WebSocketServer } from "ws";
import { JsonObject, ProtocolError } from "./json.js";
import { ModelTransport, OpenAIResponsesTransport } from "./astra/client.js";
import { AstraSession, SessionSink } from "./session.js";
import { ClientEnvelope, MAX_OUTGOING_BUFFER_BYTES, MAX_WIRE_BYTES, SessionHello, parseWireText } from "./protocol.js";

export interface ServiceOptions {
  host: string;
  port: number;
  apiKey?: string;
  accessToken?: string;
  model?: ModelTransport;
  fetchImpl?: typeof fetch;
}

export class SessionServer {
  private readonly http: Server;
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: MAX_WIRE_BYTES });
  private readonly sessions = new Map<string, AstraSession>();
  private readonly fetchImpl: typeof fetch;
  private readonly model: ModelTransport;

  constructor(private readonly options: ServiceOptions) {
    if (!isLoopback(options.host) && !options.accessToken) throw new Error("SESSION_ACCESS_TOKEN is required when listening beyond loopback");
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.model = options.model ?? new OpenAIResponsesTransport(requireApiKey(options.apiKey), this.fetchImpl);
    this.http = createServer((request, response) => { void this.handleHttp(request, response); });
    this.http.on("upgrade", (request, socket, head) => {
      if (new URL(request.url ?? "/", "http://localhost").pathname !== "/session") { socket.destroy(); return; }
      this.wss.handleUpgrade(request, socket, head, (ws) => this.handleConnection(ws));
    });
  }

  listen(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.http.once("error", reject);
      this.http.listen(this.options.port, this.options.host, () => { this.http.off("error", reject); resolve(); });
    });
  }

  async close(): Promise<void> {
    await new Promise<void>((resolve, reject) => this.wss.close((error) => error ? reject(error) : resolve()));
    await new Promise<void>((resolve, reject) => this.http.close((error) => error ? reject(error) : resolve()));
  }

  address(): string {
    const address = this.http.address();
    if (!address || typeof address === "string") return "";
    return `http://${address.address}:${address.port}`;
  }

  private handleConnection(ws: WebSocket): void {
    let session: AstraSession | undefined;
    let hello: SessionHello | undefined;
    const sink: SessionSink = { send: (message) => {
      if (ws.readyState !== WebSocket.OPEN) return;
      if (ws.bufferedAmount > MAX_OUTGOING_BUFFER_BYTES) { ws.close(1013, "outgoing queue exceeded"); return; }
      const text = JSON.stringify(message);
      if (Buffer.byteLength(text, "utf8") > MAX_WIRE_BYTES) { ws.close(1009, "outgoing message exceeded"); return; }
      ws.send(text);
    }};
    ws.on("message", (data, isBinary) => {
      if (isBinary) { this.sendError(sink, "", "invalid_message", "binary frames are not supported"); return; }
      try {
        const message = parseWireText(data.toString());
        if (!hello) {
          if (message.type !== "session.hello") throw new ProtocolError("session.hello is required first", "hello_required");
          this.authorize(message.authToken);
          hello = message;
          session = this.sessions.get(message.sessionId) ?? new AstraSession(this.model, sink);
          session.attachSink(sink);
          this.sessions.set(message.sessionId, session);
          session.acceptHello(message);
          return;
        }
        if (!session) throw new ProtocolError("session is unavailable", "session_unavailable");
        void this.dispatch(session, message, sink);
      } catch (error) {
        const known = error instanceof ProtocolError ? error : new ProtocolError("invalid message");
        this.sendError(sink, "", known.code, known.message);
      }
    });
  }

  private async dispatch(session: AstraSession, message: ClientEnvelope, sink: SessionSink): Promise<void> {
    try {
      switch (message.type) {
        case "phone.snapshot": session.updateSnapshot(message); break;
        case "user.request": await session.request(message); break;
        case "session.cancel": session.cancel(message.requestId); break;
        case "user.stop": case "user.undo": session.fence(message.sceneId, message.intentEpoch); break;
        case "scene.receipt": session.receiveReceipt(message); break;
        case "generation.receipt": session.receiveGenerationReceipt(message); break;
        case "session.hello": throw new ProtocolError("session.hello may only be sent once", "duplicate_hello");
      }
    } catch (error) {
      const known = error instanceof ProtocolError ? error : new ProtocolError(error instanceof Error ? error.message : "session failure", "session_failed");
      this.sendError(sink, message.type === "user.request" ? message.requestId : "", known.code, known.message);
    }
  }

  private async handleHttp(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const path = new URL(request.url ?? "/", "http://localhost").pathname;
    if (request.method === "GET" && path === "/health") {
      this.respondJson(response, 200, { status: "ok", openaiConfigured: Boolean(this.options.apiKey), protocolVersion: 1 });
      return;
    }
    if (request.method === "POST" && path === "/realtime/client-secret") {
      try {
        this.authorizeHeader(request.headers.authorization);
        const body = await readJsonBody(request);
        if (typeof body.sessionId !== "string" || body.sessionId.length === 0) throw new ProtocolError("sessionId is required");
        const key = requireApiKey(this.options.apiKey);
        const upstream = await this.fetchImpl("https://api.openai.com/v1/realtime/client_secrets", {
          method: "POST",
          headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
          body: JSON.stringify({ session: { type: "realtime", model: "gpt-realtime-2.1", reasoning: { effort: "low" }, audio: { output: { voice: "marin" } } } })
        });
        const payload = await upstream.json() as unknown;
        if (!upstream.ok || !isClientSecret(payload)) throw new Error(`Realtime credential request failed (${upstream.status})`);
        this.respondJson(response, 200, { clientSecret: { value: payload.value, expires_at: payload.expires_at }, model: payload.session.model });
      } catch (error) {
        const known = error instanceof ProtocolError ? error : new ProtocolError(error instanceof Error ? error.message : "credential request failed", "credential_failed");
        this.respondJson(response, known.code === "unauthorized" ? 401 : 400, { error: { code: known.code, message: known.message } });
      }
      return;
    }
    this.respondJson(response, 404, { error: { code: "not_found", message: "not found" } });
  }

  private authorize(token: string | undefined): void { if (this.options.accessToken && !sameToken(token, this.options.accessToken)) throw new ProtocolError("invalid session token", "unauthorized"); }
  private authorizeHeader(header: string | undefined): void {
    if (!this.options.accessToken) return;
    const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : undefined;
    this.authorize(token);
  }
  private sendError(sink: SessionSink, requestId: string, code: string, message: string): void { sink.send({ type: "session.error", requestId, code, message }); }
  private respondJson(response: ServerResponse, status: number, value: JsonObject): void {
    response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
    response.end(JSON.stringify(value));
  }
}

function requireApiKey(value: string | undefined): string { if (!value) throw new Error("OPENAI_API_KEY is required"); return value; }
function isLoopback(host: string): boolean { return host === "127.0.0.1" || host === "::1" || host === "localhost"; }
function sameToken(candidate: string | undefined, expected: string): boolean {
  if (!candidate) return false;
  const left = Buffer.from(candidate); const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}
async function readJsonBody(request: IncomingMessage): Promise<JsonObject> {
  const chunks: Buffer[] = []; let bytes = 0;
  for await (const chunk of request) { const buffer = Buffer.from(chunk); bytes += buffer.length; if (bytes > 16 * 1024) throw new ProtocolError("request body exceeds 16 KiB"); chunks.push(buffer); }
  let parsed: unknown;
  try { parsed = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw new ProtocolError("request body is not JSON"); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new ProtocolError("request body must be an object");
  return parsed as JsonObject;
}
function isClientSecret(value: unknown): value is { value: string; expires_at: number; session: { model: string } } {
  if (!value || typeof value !== "object") return false;
  const candidate = value as { value?: unknown; expires_at?: unknown; session?: unknown };
  return typeof candidate.value === "string" && typeof candidate.expires_at === "number" && Boolean(candidate.session && typeof candidate.session === "object" && typeof (candidate.session as { model?: unknown }).model === "string");
}
