"""Acquire the published EVT3 motherboard collateral and EVT thermal drawings."""
import concurrent.futures, hashlib, json, subprocess, sys, urllib.parse, urllib.request
from acquire import ROOT, log

REPO = 'opencomputeproject/zaius-barreleye-g2'
PATHS = [
    'HW/EE/GBR/EVT/MB/Zaius-EVT3-LAYOUT-MB-GBR-X02-20161226-Final.zip',
    'HW/EE/GBR/EVT/MB/Zaius-EVT3-LAYOUT-MB-ODB-X02-20161226-Final.zip',
    'HW/EE/BRD/EVT/Zaius-EVT3-LAYOUT-MB-BRD-X02-20161226-Final.zip',
    'HW/EE/SCH/EVT/MB.zip',
    'HW/EE/BoM/EVT/ZAIUS-MB-EVT3-HW-EBOM-X00_20161228-add_2nd_source_X15-20170106-Final.xls',
    'HW/thermal/EVT/G2-CPU HSK-Furukawa-HS855600.pdf',
    'HW/thermal/EVT/Zaius-VTM-1-HS855360-C.pdf',
    'HW/thermal/EVT/Zaius-VTM-2-HS855370-C.pdf',
]

def acquire(path):
    raw = f'https://raw.githubusercontent.com/{REPO}/master/' + urllib.parse.quote(path)
    log('metadata-fetch-start', url=raw, method='urllib.request.urlopen')
    data = urllib.request.urlopen(raw, timeout=60).read()
    log('metadata-fetch-complete', url=raw, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    if data.startswith(b'version https://git-lfs'):
        pointer = data.decode()
        size = int(pointer.split('size ')[1])
        sha = pointer.split('oid sha256:')[1].splitlines()[0]
        url = f'https://media.githubusercontent.com/media/{REPO}/master/' + urllib.parse.quote(path)
    else:
        size = len(data); sha = hashlib.sha256(data).hexdigest(); url = raw
    if size > 500000000:
        log('size-threshold', path=path, bytes=size)
        raise RuntimeError(f'{path} exceeds 500 MB; report before downloading')
    argv = [sys.executable, str(ROOT / 'scripts/acquire.py'), url,
            'originals/zaius-barreleye-g2/' + path, '--bytes', str(size), '--sha256', sha]
    subprocess.run(argv, check=True)

if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(acquire, PATHS): pass
