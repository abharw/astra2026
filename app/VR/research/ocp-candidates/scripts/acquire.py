"""Public file acquisition with observable action log and SHA-256 pinning."""
import argparse, datetime, hashlib, json, pathlib, sys, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]

def log(kind, **data):
    event = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 actor='rack_openhardware_research', kind=kind, **data)
    with (ROOT / 'actions.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('url'); p.add_argument('destination')
    p.add_argument('--bytes', type=int); p.add_argument('--sha256')
    a = p.parse_args()
    log('download-start', argv=sys.argv, url=a.url, destination=a.destination,
        expected_bytes=a.bytes, expected_sha256=a.sha256)
    dest = ROOT / a.destination
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + '.part')
    digest = hashlib.sha256(); count = 0
    try:
        with urllib.request.urlopen(a.url, timeout=90) as response, partial.open('wb') as out:
            while True:
                chunk = response.read(4 * 1024 * 1024)
                if not chunk: break
                out.write(chunk); digest.update(chunk); count += len(chunk)
        if a.bytes is not None and count != a.bytes: raise RuntimeError('Size mismatch')
        if a.sha256 is not None and digest.hexdigest() != a.sha256: raise RuntimeError('Hash mismatch')
        partial.rename(dest)
        record = dict(url=a.url, file=a.destination, bytes=count, sha256=digest.hexdigest(),
                      status='verified' if a.sha256 else 'downloaded',
                      retrieved_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        with (ROOT / 'source-register.jsonl').open('a') as f: f.write(json.dumps(record) + '\n')
        log('download-complete', **record)
        print(json.dumps(record))
    except Exception as exc:
        log('download-failed', url=a.url, destination=a.destination, bytes=count, error=str(exc))
        raise
