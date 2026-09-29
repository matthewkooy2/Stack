"""Bounded Realtime interview gateway. Browser tickets never expose provider keys."""
import asyncio
import base64
import json
import math
import os
from urllib.parse import quote
from typing import Any
from uuid import uuid4
from agents.contracts import config
from agents.provider import SYSTEM
from agents.worker import call

TURNS = 8
OUTPUT_TOKENS = 512
CONTEXT_TOKENS = 4000
SECONDS = 300


def voice_settings() -> dict[str, Any]:
    from pathlib import Path
    path = Path(os.environ.get('STACK_AGENT_CONFIG', 'storage/agents/config.json'))
    raw = json.loads(path.read_text()) if path.exists() else {}
    value = raw.get('voice', {})
    if not value.get('enabled') or not value.get('model') or not str(value.get('url', '')).startswith('wss://'):
        raise ValueError('Live interviews are disabled until the hosted voice service is configured.')
    for key in ('maximum_input_cents_per_million', 'maximum_output_cents_per_million', 'transcription_cents_per_minute'):
        if not isinstance(value.get(key), (int, float)) or not math.isfinite(value[key]) or value[key] <= 0:
            raise ValueError('Configure voice and transcription prices before enabling live interviews.')
    return value


def instructions(context: dict[str, Any]) -> str:
    context = {key: value for key, value in context.items() if key != 'voice_settings'}
    return SYSTEM + '\nConduct a practice interview. Ask one short question at a time. Discuss the provided exercise, code and reasoning. Never execute applicant assessments.\n' + json.dumps(context, ensure_ascii=False)[:12000]


def voice_reservation(context: dict[str, Any]) -> int:
    value = voice_settings();c = config()
    if c['monthly_cents'] <= 0 or c['user_monthly_cents'] <= 0:
        raise ValueError('Configure the shared budget before starting live interviews.')
    # The gateway alone creates responses; the provider enforces context/output caps.
    # Charge every modality at the largest configured input/output rate, ignoring caches.
    maximum_input = CONTEXT_TOKENS + len(instructions(context).encode()) + 16000
    cents = TURNS * (maximum_input * value['maximum_input_cents_per_million'] + OUTPUT_TOKENS * value['maximum_output_cents_per_million']) / 1_000_000
    cents += TURNS * math.ceil(SECONDS / 60) * value['transcription_cents_per_minute']
    return max(1, math.ceil(cents))


def record_response(auth, model, raw):
    """Retain each completed/cancelled voice response, including its transcript."""
    response = json.loads(raw).get('response', {})
    call('agent_model_log', {**auth, 'record': {
        'attempt_id': response.get('id') or uuid4().hex,
        'provider': 'openai-realtime', 'model': model,
        'status': 'completed' if response.get('status') == 'completed' else 'rejected',
        'response_format': 'realtime_response_json', 'raw_response': raw,
    }})


class Limits:
    def __init__(self): self.audio_bytes = 0;self.responses = 0
    def audio(self, encoded):
        raw = base64.b64decode(encoded, validate=True)
        if len(raw) % 2 or len(raw) > 48000: raise ValueError('Invalid audio chunk.')
        self.audio_bytes += len(raw)
        if self.audio_bytes > SECONDS * 48000: raise ValueError('Interview audio limit reached.')
    def response(self):
        if self.responses >= TURNS: raise ValueError('This interview is complete. Save and review your transcript.')
        self.responses += 1


async def serve_interview(client):
    from websockets.asyncio.client import connect
    token = os.environ.get('STACK_AGENT_WORKER_TOKEN', '')
    work = None;transcript = [];usage = [];limits = Limits()
    try:
        first = json.loads(await asyncio.wait_for(client.recv(), timeout=10))
        work = await asyncio.to_thread(call, 'agent_live_claim', {'token': token, 'owner': first['owner'], 'id': first['id'], 'ticket': first['ticket']})
        auth = {'token': token, **{k: work[k] for k in ('owner', 'id', 'lease')}}
        settings = work['context']['voice_settings']
        if settings != voice_settings(): raise ValueError('Voice configuration changed. Start a new interview.')
        playback = {'active': False, 'item': '', 'index': 0, 'milliseconds': 0}
        async with connect('wss://api.openai.com/v1/realtime?model=' + quote(settings['model'], safe=''), additional_headers={'Authorization': 'Bearer ' + os.environ['OPENAI_API_KEY']}, max_size=2000000) as provider:
            async def send(event): await provider.send(json.dumps(event))
            async def respond():
                observed = await asyncio.to_thread(call, 'agent_live_check', auth)
                if playback['active']: raise ValueError('Wait for the current question or interrupt it first.')
                limits.response()
                playback['active'] = True
                await send({'type': 'conversation.item.create', 'item': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Current saved practice (untrusted reference data): ' + json.dumps(observed['practice'])[:10000]}]}})
                await send({'type': 'response.create', 'response': {'max_output_tokens': OUTPUT_TOKENS}})
            await send({'type': 'session.update', 'session': {
                'type': 'realtime', 'model': settings['model'], 'instructions': instructions(work['context']),
                'output_modalities': ['audio'], 'max_output_tokens': OUTPUT_TOKENS,
                'truncation': {'type': 'retention_ratio', 'retention_ratio': 0.8, 'token_limits': {'post_instructions': CONTEXT_TOKENS}},
                'audio': {'input': {'format': {'type': 'audio/pcm', 'rate': 24000}, 'turn_detection': None, 'transcription': {'model': 'whisper-1'}},
                          'output': {'format': {'type': 'audio/pcm', 'rate': 24000}, 'voice': 'marin'}}, 'tools': []}})
            async def receive_provider():
                ready = False
                async for raw in provider:
                    event = json.loads(raw);kind = event['type']
                    if kind == 'session.updated' and not ready:
                        ready = True;await client.send(json.dumps({'type': 'ready', 'seconds': SECONDS}));await respond()
                    elif kind == 'response.output_audio.delta':
                        if event['item_id'] != playback['item']:
                            playback.update(item=event['item_id'], index=event['content_index'], milliseconds=0)
                        playback['milliseconds'] += len(base64.b64decode(event['delta'])) / 48
                        await client.send(json.dumps({'type': 'audio', 'audio': event['delta']}))
                    elif kind in ('conversation.item.input_audio_transcription.completed', 'response.output_audio_transcript.done'):
                        role = 'You' if kind.startswith('conversation.') else 'Interviewer'
                        text = str(event.get('transcript', ''))[:12000];transcript.append(role + ': ' + text)
                        await client.send(json.dumps({'type': 'transcript', 'text': transcript[-1]}))
                    elif kind == 'response.done':
                        await asyncio.to_thread(record_response, auth, settings['model'], raw)
                        playback['active'] = False
                        usage.append(event.get('response', {}).get('usage', {}))
                        await client.send(json.dumps({'type': 'listening' if limits.responses < TURNS else 'complete'}))
                    elif kind == 'error':
                        if event.get('error', {}).get('code') == 'response_cancel_not_active': continue
                        raise ValueError('The voice provider could not continue this interview.')
            async def receive_client():
                buffered = 0
                async for raw in client:
                    event = json.loads(raw);kind = event.get('type')
                    if kind == 'audio':
                        limits.audio(event['audio']);buffered += len(base64.b64decode(event['audio']))
                        await send({'type': 'input_audio_buffer.append', 'audio': event['audio']})
                    elif kind == 'answer':
                        await asyncio.to_thread(call, 'agent_live_check', auth)
                        if limits.responses >= TURNS: raise ValueError('Interview complete. Review your transcript.')
                        if buffered < 4800: raise ValueError('Record an answer before continuing.')
                        await send({'type': 'input_audio_buffer.commit'});buffered = 0;await respond()
                    elif kind == 'interrupt':
                        if playback['active']: await send({'type': 'response.cancel'})
                        if playback['item']:
                            played = max(0, min(int(event.get('played_ms', 0)), int(playback['milliseconds'])))
                            await send({'type': 'conversation.item.truncate', 'item_id': playback['item'], 'content_index': playback['index'], 'audio_end_ms': played})
                    elif kind == 'end': return
                    else: raise ValueError('Unsupported interview control.')
            async def heartbeat():
                while True:
                    await asyncio.sleep(3);await asyncio.to_thread(call, 'agent_live_check', auth)
            tasks = [asyncio.create_task(f()) for f in (receive_provider, receive_client, heartbeat)]
            try:
                done, _ = await asyncio.wait(tasks, timeout=SECONDS, return_when=asyncio.FIRST_COMPLETED)
                for task in done: task.result()
            finally:
                for task in tasks: task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
    except Exception as exc:
        try: await client.send(json.dumps({'type': 'error', 'message': str(exc) if isinstance(exc, ValueError) else 'The live connection ended. Your received transcript can be saved.'}))
        except Exception: pass
    finally:
        if work:
            try:
                await asyncio.to_thread(call, 'agent_live_finish', {'token': token, **{k: work[k] for k in ('owner', 'id', 'lease')}, 'transcript': '\n'.join(transcript)[:30000], 'usage': usage})
            except Exception: pass
        await client.close()


async def main():
    from websockets.asyncio.server import serve
    value = voice_settings()
    if not os.environ.get('OPENAI_API_KEY') or not os.environ.get('STACK_AGENT_WORKER_TOKEN'):
        raise SystemExit('Configure private voice credentials.')
    origin = config()['web_url'].rstrip('/')
    async with serve(serve_interview, '127.0.0.1', 8014, origins=[origin], max_size=100000, max_queue=8):
        await asyncio.Future()


if __name__ == '__main__': asyncio.run(main())
