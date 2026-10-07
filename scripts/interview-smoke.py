"""Opt-in local Qwen acceptance with synthetic accounts and persisted reviewed answers."""
import argparse
import json
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path('tests').resolve()))
from test_interview import Journey

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model',required=True)
    parser.add_argument('--url',default='http://127.0.0.1:1234')
    parser.add_argument('--provider',choices=['lmstudio','ollama'],default='lmstudio')
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='stack-interview-live-') as directory:
        journey=Journey(directory,args.url,args.model,args.provider)
        try:
            done=journey.complete()
            print(json.dumps({'provider':args.provider,'requested_model':args.model,'inference':'real local Qwen',
                'timings':journey.timings,'persisted_after_reload':True,'conversation':done['data'],
                'run':done['run']},indent=2),flush=True)
        finally:journey.close()

if __name__=='__main__':main()
