import json, plistlib, secrets, pathlib, sys
root=pathlib.Path(__file__).resolve().parent
url=sys.argv[1] if len(sys.argv)>1 else input("HTTPS tunnel URL: ").strip()
if not url.startswith("https://"): raise SystemExit("An HTTPS URL is required")
c={"url":url,"token":secrets.token_urlsafe(32)}
(root/"private").mkdir(exist_ok=True)
p=root/"private/connection.json"; p.write_text(json.dumps(c)); p.chmod(0o600)
p=root/"ios/SpatialAssembly/Connection.plist"; p.write_bytes(plistlib.dumps(c)); p.chmod(0o600)
print("Paired local configuration created. Rebuild the iPhone app.")
