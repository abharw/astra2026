"""Append observable production events or execute an explicitly supplied command.

Never pass credentials in arguments. Tool/browser actions can be recorded with
`event`; subprocess mode retains the exact command and stdout/stderr locally.
"""
import argparse
import datetime
import hashlib
import json
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def record(kind, detail, **extra):
    item = dict(id=str(uuid.uuid4()), recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), actor='root', kind=kind, detail=detail, **extra)
    path = ROOT / 'logs/actions.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as f:
        f.write(json.dumps(item, ensure_ascii=False) + '\n')
    return item

if __name__ == '__main__':
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='mode',required=True)
    e=sub.add_parser('event');e.add_argument('kind');e.add_argument('detail');e.add_argument('--retrospective',action='store_true')
    c=sub.add_parser('run');c.add_argument('--label',required=True);c.add_argument('--cwd',default=str(ROOT));c.add_argument('command',nargs=argparse.REMAINDER)
    a=p.parse_args()
    if a.mode=='event':
        print(json.dumps(record(a.kind,a.detail,retrospective=a.retrospective)))
    else:
        cmd=a.command[1:] if a.command[:1]==['--'] else a.command
        if not cmd:p.error('command is required')
        start=record('command-start',a.label,argv=cmd,cwd=str(Path(a.cwd).resolve()))
        raw=ROOT/'logs/raw'/f"{start['id']}.log";raw.parent.mkdir(parents=True,exist_ok=True)
        with raw.open('wb') as out:
            try:
                proc=subprocess.Popen(cmd,cwd=a.cwd,stdout=out,stderr=subprocess.STDOUT)
                rc=proc.wait()
            except OSError as exc:
                out.write(str(exc).encode());rc=127
        record('command-end',a.label,start_id=start['id'],exit_code=rc,raw_log=str(raw.relative_to(ROOT)),log_sha256=hashlib.sha256(raw.read_bytes()).hexdigest())
        print(raw.read_text(errors='replace')[-12000:]);sys.exit(rc)
