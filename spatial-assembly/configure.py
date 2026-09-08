import argparse, json, pathlib, plistlib, secrets
parser = argparse.ArgumentParser(description="Pair the iPhone and Quest clients with the local bridge")
parser.add_argument("url", help="HTTPS tunnel URL")
parser.add_argument("--rotate", action="store_true", help="Replace the bridge token; rebuild both clients")
args = parser.parse_args()
if not args.url.startswith("https://"):
    raise SystemExit("An HTTPS URL is required")
root = pathlib.Path(__file__).resolve().parent
private = root / "private/connection.json"
old = json.loads(private.read_text()) if private.exists() else {}
config = {"url": args.url.rstrip("/"), "token": secrets.token_urlsafe(32) if args.rotate else old.get("token", secrets.token_urlsafe(32))}
for path in (private, root.parent / "quest/Assets/StreamingAssets/connection.json"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config))
    path.chmod(0o600)
path = root / "ios/SpatialAssembly/Connection.plist"
path.write_bytes(plistlib.dumps(config))
path.chmod(0o600)
print("Paired local configuration written for iPhone and Quest. Rebuild clients to bundle changes.")
