"""One collection lease over the existing Jac worker API; no local persistence."""
import json
import os
from typing import Any
from urllib.request import Request, urlopen
from discovery.sources import collect


def call(name: str, args: dict[str, Any]) -> dict[str, Any]:
    request = Request(os.environ.get('STACK_WORKER_API', 'http://127.0.0.1:8000')+
                      '/function/'+name, data=json.dumps(args).encode(),
                      headers={'Content-Type': 'application/json'})
    with urlopen(request, timeout=90) as response:
        result = json.load(response)['data']['result']
    if result.get('error'):
        raise ValueError(result['error'])
    return result


def batch(token: str, source_id: str='') -> dict[str, Any]:
    work = call('discovery_claim', {'token': token, 'preferred_id': source_id})
    if work.get('idle'):
        return {'idle': True}
    result = {}; error = ''
    try:
        result = collect(work['config'], work['checkpoint'])
    except Exception as exc:
        error = str(exc) if isinstance(exc, ValueError) else 'Source could not be collected ('+type(exc).__name__+').'
    call('discovery_complete', {'token': token, 'id': work['id'], 'lease': work['lease'],
                               'result': result, 'error': error})
    return {'id': work['id'], 'result': result, 'error': error}
