"""Coarse component readiness on the existing public web response. No user data."""
import json
import os
from pathlib import Path
import time
import uuid

PATH=Path('.jac/transcription/readiness.json')
STAGES={'checking','toolchain','source','building','model','probe','ready','failed'}
TOOLS={'git','cmake','cc','c++'}

def public_status() -> dict[str, str]:
    try:
        if PATH.stat().st_size>8192:raise ValueError('Invalid readiness record')
        data=json.loads(PATH.read_text())
        if not isinstance(data,dict):raise ValueError('Invalid readiness record')
        # A stopped worker cannot retain a ready signal indefinitely.
        if time.time()-float(data.get('updated_at',0))>45:raise ValueError('Stale readiness')
    except (OSError,ValueError,TypeError):data={}
    status=data.get('status','pending');status=status if isinstance(status,str) and status in ('pending','preparing','ready','unavailable') else 'pending'
    stage=data.get('stage','checking');stage=stage if isinstance(stage,str) and stage in STAGES else 'checking'
    missing=','.join(sorted(x for x in (data.get('missing_tools') or []) if isinstance(x,str) and x in TOOLS))
    return {'state':status,'stage':stage,'probe':'passed' if data.get('probe_passed') is True and status=='ready' else 'pending','missing':missing}

def publish(data):
    PATH.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    # The owner-visible message is intentionally excluded from public headers.
    value={k:data.get(k) for k in ('status','stage','probe_passed','missing_tools')}
    value['updated_at']=time.time()
    temporary=PATH.with_name('readiness-'+uuid.uuid4().hex+'.tmp');temporary.write_text(json.dumps(value));temporary.chmod(0o600);os.replace(temporary,PATH)
