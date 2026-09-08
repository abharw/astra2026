import { SessionServer } from "./server.js";

const host = process.env.ASTRA_SESSION_HOST ?? "127.0.0.1";
const port = Number.parseInt(process.env.ASTRA_SESSION_PORT ?? "8787", 10);
if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("ASTRA_SESSION_PORT must be a valid port");

const server = new SessionServer({ host, port, apiKey: process.env.OPENAI_API_KEY, accessToken: process.env.SESSION_ACCESS_TOKEN });
await server.listen();
console.log(`Astra session service listening on ${server.address()}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => { void server.close().finally(() => process.exit(0)); });
}
