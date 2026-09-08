#!/usr/bin/env python3
"""Run the local session service and configure a development device without printing secrets."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "runtime" / "dev-session.json"
APP_IDENTIFIER = "com.astra.spatialdemo"


def read_config():
    try:
        config = json.loads(CONFIG.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(config, dict) or not isinstance(config.get("url"), str) or not isinstance(config.get("token"), str):
        return None
    return config


def write_config(config):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    # Open with restrictive permissions before writing the temporary development credential.
    fd = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(config, handle)


def select_target(args):
    if args.device:
        return "device", args.device
    return "simulator", args.simulator_id


def diagnostics_destination(target):
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    safe_target = "".join(character if character.isalnum() or character in "._-" else "_" for character in target)
    return ROOT / "runtime" / "diagnostics" / f"{timestamp}-{safe_target}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Run the Doppler-backed service on this Mac's Wi-Fi address")
    serve.add_argument("--host", help="Explicit local bind address (default: en0 address)")
    serve.add_argument("--port", type=int, default=8788)
    serve.add_argument("--rotate-token", action="store_true", help="Replace the saved local session token")
    launch = commands.add_parser("launch", help="Launch the installed Debug app with this local service configuration")
    logs = commands.add_parser("logs", help="Copy redacted app diagnostics into ignored runtime state")
    for command in (launch, logs):
        target = command.add_mutually_exclusive_group(required=True)
        target.add_argument("--device", help="Physical device name or identifier")
        target.add_argument("--simulator-id", help="Simulator UDID; use this instead of an ambiguous booted simulator")
    args = parser.parse_args()

    if args.command == "serve":
        host = args.host or subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True).strip()
        if not host or not 1 <= args.port <= 65535:
            parser.error("A local host address and valid port are required")
        url = f"http://{host}:{args.port}"
        existing = read_config()
        if existing and existing["url"] == url and not args.rotate_token:
            config = existing
        else:
            config = {"url": url, "token": secrets.token_urlsafe(32)}
            write_config(config)
        env = os.environ.copy()
        log_dir = ROOT / "runtime" / "logs" / f"backend-{args.port}"
        log_dir.mkdir(parents=True, exist_ok=True)
        env.update(ASTRA_SESSION_HOST=host, ASTRA_SESSION_PORT=str(args.port), SESSION_ACCESS_TOKEN=config["token"], ASTRA_LOG_DIR=str(log_dir))
        print(f"Development service: {config['url']} (session token kept in ignored runtime directory)", flush=True)
        os.chdir(ROOT / "services" / "session")
        os.execvpe("doppler", ["doppler", "run", "--project", "backend", "--config", "dev", "--only-secrets", "OPENAI_API_KEY", "--", "npm", "start"], env)
    elif args.command == "launch":
        if not CONFIG.exists():
            parser.error("Run serve first in another terminal")
        config = read_config()
        if not config:
            parser.error("The local development session config is missing or invalid; run serve again")
        env = os.environ.copy()
        target_kind, target_id = select_target(args)
        prefix = "SIMCTL_CHILD_" if target_kind == "simulator" else "DEVICECTL_CHILD_"
        env[prefix + "ASTRA_BACKEND_URL"] = config["url"]
        env[prefix + "ASTRA_SESSION_TOKEN"] = config["token"]
        if target_kind == "simulator":
            command = ["xcrun", "simctl", "launch", "--terminate-running-process", target_id, APP_IDENTIFIER]
        else:
            command = ["xcrun", "devicectl", "device", "process", "launch", "--device", target_id, "--terminate-existing", APP_IDENTIFIER]
        raise SystemExit(subprocess.call(command, env=env))
    else:
        target_kind, target_id = select_target(args)
        destination = diagnostics_destination(target_id)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if target_kind == "device":
            command = ["xcrun", "devicectl", "device", "copy", "from", "--device", target_id, "--domain-type", "appDataContainer", "--domain-identifier", APP_IDENTIFIER, "--source", "Documents/AstraDiagnostics", "--destination", str(destination), "--timeout", "30"]
            raise SystemExit(subprocess.call(command))
        container = subprocess.check_output(["xcrun", "simctl", "get_app_container", target_id, APP_IDENTIFIER, "data"], text=True).strip()
        source = Path(container) / "Documents" / "AstraDiagnostics"
        if not source.is_dir():
            parser.error("The simulator has no Documents/AstraDiagnostics directory yet")
        shutil.copytree(source, destination)
        print(f"Copied diagnostics to {destination.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
