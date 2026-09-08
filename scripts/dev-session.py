#!/usr/bin/env python3
"""Run the local session service and configure a development device without printing secrets."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "runtime" / "dev-session.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Run the Doppler-backed service on this Mac's Wi-Fi address")
    serve.add_argument("--host", help="Explicit local bind address (default: en0 address)")
    serve.add_argument("--port", type=int, default=8788)
    launch = commands.add_parser("launch", help="Launch the installed Debug app with this local service configuration")
    launch.add_argument("--device", help="Physical device name or identifier")
    launch.add_argument("--simulator", action="store_true")
    args = parser.parse_args()

    if args.command == "serve":
        host = args.host or subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True).strip()
        if not host or not 1 <= args.port <= 65535:
            parser.error("A local host address and valid port are required")
        config = {"url": f"http://{host}:{args.port}", "token": secrets.token_urlsafe(32)}
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        # Open with restrictive permissions before writing the temporary development credential.
        fd = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(config, handle)
        env = os.environ.copy()
        env.update(ASTRA_SESSION_HOST=host, ASTRA_SESSION_PORT=str(args.port), SESSION_ACCESS_TOKEN=config["token"])
        print(f"Development service: {config['url']} (session token kept in ignored runtime directory)", flush=True)
        os.chdir(ROOT / "services" / "session")
        os.execvpe("doppler", ["doppler", "run", "--project", "backend", "--config", "dev", "--only-secrets", "OPENAI_API_KEY", "--", "npm", "start"], env)
    else:
        if args.simulator == bool(args.device):
            parser.error("Choose exactly one of --device or --simulator")
        if not CONFIG.exists():
            parser.error("Run serve first in another terminal")
        config = json.loads(CONFIG.read_text())
        env = os.environ.copy()
        prefix = "SIMCTL_CHILD_" if args.simulator else "DEVICECTL_CHILD_"
        env[prefix + "ASTRA_BACKEND_URL"] = config["url"]
        env[prefix + "ASTRA_SESSION_TOKEN"] = config["token"]
        if args.simulator:
            command = ["xcrun", "simctl", "launch", "--terminate-running-process", "booted", "com.astra.spatialdemo"]
        else:
            command = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device, "--terminate-existing", "com.astra.spatialdemo"]
        raise SystemExit(subprocess.call(command, env=env))


if __name__ == "__main__":
    main()
