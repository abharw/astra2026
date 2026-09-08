# Backend endpoint and device connectivity

The iPhone/iPad renders and hit-tests the scene locally. It needs a reachable session service for Astra authoring and short-lived Realtime credentials. That service is a normal Node process, currently run on the development Mac. `tools/Sources/SceneLab` and `tools/Sources/PointingReplay` are acceptance clients, not services that the app needs running.

## What failed on the iPhone

On September 8, the app's direct `ws://<Mac Wi-Fi address>:8788/session` connection failed before `session.hello` reached the service. The device reported offline/cannot-connect errors, while the same service's health check succeeded on the Mac. Arav confirmed Local Network permission was enabled and both devices used the same Wi-Fi; the Mac firewall was disabled. These facts isolate the failing route but do not identify a particular router setting.

With the same signed app, same backend and same session token, switching only the address to an authenticated HTTPS/WSS tunnel succeeded. The physical iPhone received `session.accepted`, obtained a Realtime credential, received Realtime's configuration acknowledgement and logged `connection.finished` with `ready=true`. This took 2.212 seconds from the scene connection request. [Redacted evidence](evidence/iphone-endpoint-connection.json).

The previous UI replaced the transport cause with “Couldn't reach Astra.” A service that cannot be reached, rejected authentication, and a failed provider connection are different stages; diagnostics and recovery must preserve that distinction. Apple recommends waiting for connectivity while local-network permission resolves, and documents the distinction between a denied local-network path and other networking failures. [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Development route

Start the authenticated local service:

```sh
python3 tools/dev-session.py serve
python3 tools/dev-session.py doctor
```

On a network that does not permit phone-to-Mac connections, forward that same authenticated service with an HTTPS tunnel. With the installed Cloudflare CLI, supply the address printed by `serve`:

```sh
cloudflared tunnel --url http://<MAC_ADDRESS>:8788 --no-autoupdate
python3 tools/dev-session.py doctor --url https://<TUNNEL_HOST>
python3 tools/dev-session.py launch --device <DEVICE_ID> --url https://<TUNNEL_HOST>
```

`launch --url` retains the saved development-service token and sends it to the app without printing it. Use an endpoint forwarding to that service, with the same credential. The app stores the address in preferences and its token in Keychain for ordinary icon launches. A health check only proves reachability from the machine running it; device diagnostics prove the phone connection. Neither check submits a model turn.

This temporary tunnel still needs both Mac processes running. Its address can change when restarted. It is a development bridge, not a stable hosted deployment. The unauthenticated credential endpoint returns 401, and a scene handshake without the token is rejected. Never expose the unauthenticated loopback test service through a tunnel.

## Standalone endpoint

For audience phones, deploy `backend` behind a stable HTTPS endpoint on a host that supports long-lived WebSockets. The service owns API credentials and acknowledged session context; assets remain bundled or approved by the native asset catalog, and rendering stays on the device. The phone uses the endpoint for `/session` and `/realtime/client-secret`, then connects directly to OpenAI Realtime with its ephemeral credential.

The service's [container and production commands](../backend/README.md) provide this deployment boundary. Inject `OPENAI_API_KEY` and `SESSION_ACCESS_TOKEN` in the host's secret configuration. Use one replica for the current in-memory sessions. A server restart ends active turns; clients reconnect with their accepted scene snapshot. Session persistence, user accounts, per-user quotas and multi-replica routing are separate work, not prerequisites for the current controlled demo. No cloud deployment has been created by this change.
