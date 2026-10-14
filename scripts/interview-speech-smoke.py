"""Opt-in synthetic speech -> actual Whisper -> interview -> actual local Qwen.

Use disposable accounts/storage and two English 16-kHz mono PCM WAV fixtures.
Only worker/API transport is adapted to the actual Jac test client. No model,
raw Whisper output, transcription runner, scoring, or persisted result is mocked.
Known fixture text is supplied through transcript-save as simulated user review.
This is composed backend acceptance, not physical microphone/device evidence.
"""
import argparse
import base64
import hashlib
import difflib
import importlib
import json
from pathlib import Path
import re
import sys
import tempfile
import time
from unittest.mock import patch
sys.path.insert(0,str(Path('tests').resolve()))
from test_interview import Journey

TOKEN='mat5-synthetic-worker'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio',action='append',required=True)
    parser.add_argument('--model',required=True)
    parser.add_argument('--url',default='http://127.0.0.1:1234')
    args=parser.parse_args()
    if len(args.audio)!=2:parser.error('Supply exactly two --audio WAV fixtures.')
    fixture=json.loads(Path('tests/fixtures/interview-speech.json').read_text())
    with tempfile.TemporaryDirectory(prefix='mat5-real-speech-') as directory:
        journey=Journey(directory,args.url,args.model,'lmstudio')
        transcription=importlib.import_module('agents.transcription_worker')
        try:
            journey.client.clear_auth()
            transcription.runtime()  # Require installed, integrity-verified files; never provision.
            with patch.dict('os.environ',{'STACK_TRANSCRIPTION_AUTO_SETUP':'0'}),patch.object(transcription,'call',side_effect=journey.rpc):
                assert transcription.prepare_runtime(TOKEN),'Existing runtime failed its real speech probe.'
            ready=journey.rpc('transcription_processing_runtime',{'token':TOKEN})
            assert ready['status']=='ready' and ready['probe_passed'],ready
            steps=[]
            for index,filename in enumerate(args.audio):
                raw=Path(filename).read_bytes();journey.client.set_auth_token(journey.tokens[0])
                recording=journey.rpc('transcription_upload',{'client_id':'mat5-real-speech-'+str(index),'content':base64.b64encode(raw).decode()})
                journey.client.clear_auth();began=time.monotonic()
                with patch.object(transcription,'call',side_effect=journey.rpc):
                    assert transcription.run_once(TOKEN),'Transcription worker did not claim fixture.'
                journey.client.set_auth_token(journey.tokens[0])
                recording=journey.rpc('transcription_get',{'id':recording['id']})
                print(json.dumps({'stage':'actual_whisper','audio_sha256':hashlib.sha256(raw).hexdigest(),
                    'seconds':round(time.monotonic()-began,3),'recording':recording},indent=2),flush=True)
                assert recording['status']=='completed',recording.get('error')
                text=recording['transcript'];words=set(re.findall(r'[a-z]+',text.lower()))
                assert set(fixture['required_transcript_words'][index])<=words,text
                expected=re.findall(r'[a-z]+',fixture['answers'][index].lower())
                observed=re.findall(r'[a-z]+',text.lower())
                similarity=difflib.SequenceMatcher(None,expected,observed,autojunk=False).ratio()
                assert similarity>=.85,{'word_sequence_similarity':similarity,'transcript':text}
                original=text
                reviewed=fixture['answers'][index]
                recording=journey.rpc('transcription_action',{'id':recording['id'],'action':'save','text':reviewed,'revision':recording['revision']})
                assert recording['original_transcript']==original and recording['transcript']==reviewed
                text=recording['transcript']
                saved=journey.answer(text,recording['id'])
                assert saved['data']['turns'][index]['original']==recording['original_transcript']
                work,result=journey.work()
                print(json.dumps({'stage':'actual_qwen_turn','result':result,
                    'run':journey.rpc('agent_run',{'id':work['id']}),
                    'model_attempts':journey.rpc('agent_model_logs',{'id':work['id']})},indent=2),flush=True)
                assert 'artifact' in result,result
                assert result['artifact']['focus_quote'] in text
                steps.append({'recording_id':recording['id'],'audio_sha256':hashlib.sha256(raw).hexdigest(),
                              'original_transcript':original,'reviewed_transcript':text,'word_sequence_similarity':round(similarity,3),'transcription_timings':recording['timings']})
                if index==0:
                    current=journey.get();journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'followup'})
            current=journey.get();journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'finish'})
            current=journey.get();journey.rpc('interview_continue',{'id':current['id'],'revision':current['revision'],'action':'analyze'})
            work,result=journey.work()
            print(json.dumps({'stage':'actual_qwen_final','result':result,
                'run':journey.rpc('agent_run',{'id':work['id']}),
                'model_attempts':journey.rpc('agent_model_logs',{'id':work['id']})},indent=2),flush=True)
            assert 'artifact' in result,result
            journey.client.reload();journey.client.set_auth_token(journey.tokens[0]);done=journey.get()
            assert done['data']['coaching']==result['artifact'] and done['data']['status']=='finished'
            assert [turn['recording_id'] for turn in done['data']['turns']]==[row['recording_id'] for row in steps]
            assert [turn['answer'] for turn in done['data']['turns']]==[row['reviewed_transcript'] for row in steps]
            assert [turn['original'] for turn in done['data']['turns']]==[row['original_transcript'] for row in steps]
            print(json.dumps({'status':'PASS','scope':__doc__,'model':args.model,'speech_steps':steps,
                'qwen_timings':journey.timings,'persisted_after_reload':True,'conversation':done['data']},indent=2),flush=True)
        finally:journey.close()

if __name__=='__main__':main()
