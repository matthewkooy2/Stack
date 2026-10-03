"""Durable, bounded audio jobs. Called only behind Jac owner/worker authentication.

PCM validation follows the unmerged Interview Lab pilot's wav_info approach.
Audio and job metadata commit together, so a lost upload response is safe to retry.
"""
import array
import base64
from contextlib import contextmanager
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import uuid
import wave
from typing import Any

MAX_BYTES = 10 * 1024 * 1024
MAX_SECONDS = 300
ACTIVE = ('decoding', 'loading', 'transcribing')
TERMINAL = ('completed', 'failed', 'cancelled')
LEASE_SECONDS = 30


def wav_info(raw):
    if not 44 <= len(raw) <= MAX_BYTES or raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
        raise ValueError('Use a WAV recording of 10 MB or less.')
    try:
        with wave.open(io.BytesIO(raw)) as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, 'NONE'):
                raise ValueError('Use 16 kHz mono, 16-bit PCM WAV audio.')
            count = audio.getnframes()
            if not 0.3 <= count / 16000 <= MAX_SECONDS:
                raise ValueError('Record between 0.3 seconds and five minutes.')
            frames = audio.readframes(count + 1)
            if len(frames) != count * 2:
                raise ValueError('The recording is incomplete. Keep it and retry after stopping the microphone.')
    except (wave.Error, EOFError):
        raise ValueError('Invalid or interrupted WAV recording.') from None
    samples = array.array('h', frames)
    if sys.byteorder != 'little':
        samples.byteswap()
    if math.sqrt(sum(x * x for x in samples) / len(samples)) < 40:
        raise ValueError('No audible answer detected. Check your microphone and record again.')
    return count / 16000


class Store:
    def __init__(self, directory=None):
        self.directory = Path(directory or os.environ.get('STACK_TRANSCRIPTION_STORAGE', 'storage/transcription'))

    @contextmanager
    def transaction(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = self.directory / 'recordings.sqlite3'
        # Existing database contents are never replaced on restart.
        db = sqlite3.connect(path, timeout=10)
        os.chmod(path, 0o600)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('PRAGMA synchronous=FULL')
            db.execute('PRAGMA secure_delete=ON')
            db.execute('CREATE TABLE IF NOT EXISTS runtime_state (id INTEGER PRIMARY KEY, data TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS deleted_owners (owner TEXT PRIMARY KEY)')
            db.execute('CREATE TABLE IF NOT EXISTS recordings (id TEXT PRIMARY KEY, owner TEXT NOT NULL, client_id TEXT NOT NULL, digest TEXT NOT NULL, size INTEGER NOT NULL, created REAL NOT NULL, status TEXT NOT NULL, lease_until REAL NOT NULL, data TEXT NOT NULL, audio BLOB NOT NULL, UNIQUE(owner, client_id))')
            db.execute('CREATE INDEX IF NOT EXISTS transcription_queue ON recordings(status, created)')
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def access(self, db, owner):
        if not isinstance(owner, str) or not owner or db.execute('SELECT 1 FROM deleted_owners WHERE owner=?', (owner,)).fetchone():
            raise ValueError('This account is unavailable.')

    def row(self, db, owner, ident):
        self.access(db, owner)
        row = db.execute('SELECT data FROM recordings WHERE owner=? AND id=?', (owner, ident)).fetchone()
        if row is None:
            raise ValueError('Recording not found.')
        return json.loads(row['data'])

    def write(self, db, data):
        db.execute('UPDATE recordings SET status=?, lease_until=?, data=? WHERE id=? AND owner=?',
                   (data['status'], data['lease_until'], json.dumps(data), data['id'], data['owner']))

    @staticmethod
    def view(data) -> dict[str, Any]:
        return {k: v for k, v in data.items() if k not in ('owner', 'lease', 'lease_until')}

    def upload(self, owner, client_id, content) -> dict[str, Any]:
        if not isinstance(client_id, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{12,80}', client_id):
            raise ValueError('A stable recording identifier is required.')
        if not isinstance(content, str) or len(content) > (MAX_BYTES + 2) // 3 * 4:
            raise ValueError('Recording must be 10 MB or less.')
        try:
            raw = base64.b64decode(content, validate=True)
        except (ValueError, TypeError):
            raise ValueError('Invalid recording transfer.') from None
        seconds = wav_info(raw)
        digest = hashlib.sha256(raw).hexdigest()
        with self.transaction() as db:
            self.access(db, owner)
            previous = db.execute('SELECT digest, data FROM recordings WHERE owner=? AND client_id=?', (owner, client_id)).fetchone()
            if previous:
                if previous['digest'] != digest:
                    raise ValueError('This recording identifier already belongs to different audio.')
                return self.view(json.loads(previous['data']))
            owned = db.execute('SELECT COUNT(*), COALESCE(SUM(size),0) FROM recordings WHERE owner=?', (owner,)).fetchone()
            queued = db.execute("SELECT COUNT(*) FROM recordings WHERE owner=? AND status NOT IN ('completed','failed','cancelled')", (owner,)).fetchone()[0]
            total = db.execute('SELECT COALESCE(SUM(size),0) FROM recordings').fetchone()[0]
            pending = db.execute("SELECT COUNT(*) FROM recordings WHERE status NOT IN ('completed','failed','cancelled')").fetchone()[0]
            if owned[0] >= 50 or owned[1] + len(raw) > 500 * 1024 * 1024:
                raise ValueError('Recording storage is full. Delete a saved recording before uploading another.')
            if queued >= 3 or pending >= 100 or total + len(raw) > 5 * 1024**3:
                raise ValueError('The transcription queue is full. Your recording stays on this phone; retry later.')
            now = time.time()
            data = dict(id=str(uuid.uuid4()), owner=owner, client_id=client_id, created_at=now,
                        duration_seconds=seconds, size=len(raw), status='queued', attempts=0,
                        lease='', lease_until=0, stage_at=now, percent=None, error='',
                        original_transcript='', transcript='', revision=0,
                        model='whisper.cpp/base.en', timings={'transfer_ms': None, 'queue_ms': 0, 'decode_ms': 0, 'load_ms': 0, 'transcribe_ms': 0})
            db.execute('INSERT INTO recordings VALUES (?,?,?,?,?,?,?,?,?,?)',
                       (data['id'], owner, client_id, digest, len(raw), now, 'queued', 0, json.dumps(data), raw))
            return self.view(data)

    def list(self, owner) -> list[dict[str, Any]]:
        with self.transaction() as db:
            self.access(db, owner)
            return [self.view(json.loads(row[0])) for row in db.execute('SELECT data FROM recordings WHERE owner=? ORDER BY created DESC', (owner,))]

    def get(self, owner, ident) -> dict[str, Any]:
        with self.transaction() as db:
            return self.view(self.row(db, owner, ident))

    def audio(self, owner, ident) -> dict[str, Any]:
        with self.transaction() as db:
            self.row(db, owner, ident)
            raw = db.execute('SELECT audio FROM recordings WHERE owner=? AND id=?', (owner, ident)).fetchone()[0]
            return {'name': ident + '.wav', 'content': base64.b64encode(raw).decode()}

    def action(self, owner, ident, action, text='', revision=0) -> dict[str, Any]:
        with self.transaction() as db:
            data = self.row(db, owner, ident)
            if action == 'save':
                if data['status'] != 'completed':
                    raise ValueError('Wait for transcription to finish before editing.')
                if data['revision'] != revision:
                    raise ValueError('The transcript changed on another device. Reopen it before saving.')
                if not isinstance(text, str) or len(text) > 30000:
                    raise ValueError('Transcript must be 30,000 characters or less.')
                data['transcript'] = text
                data['revision'] += 1
            elif action == 'cancel':
                if data['status'] not in TERMINAL:
                    data.update(status='cancelled', lease='', lease_until=0, error='Transcription cancelled. The audio is saved; retry when ready.')
            elif action == 'retry':
                if data['status'] not in ('failed', 'cancelled'):
                    raise ValueError('Only failed or cancelled transcriptions can be retried.')
                pending = db.execute("SELECT COUNT(*) FROM recordings WHERE owner=? AND status NOT IN ('completed','failed','cancelled')", (owner,)).fetchone()[0]
                globally = db.execute("SELECT COUNT(*) FROM recordings WHERE status NOT IN ('completed','failed','cancelled')").fetchone()[0]
                if pending >= 3 or globally >= 100:
                    raise ValueError('The transcription queue is full. Retry later.')
                data.update(status='queued', attempts=0, lease='', lease_until=0, stage_at=time.time(), percent=None, error='')
                data['timings'] = {**data['timings'], 'queue_ms': 0, 'decode_ms': 0, 'load_ms': 0, 'transcribe_ms': 0}
            elif action == 'delete':
                db.execute('DELETE FROM recordings WHERE owner=? AND id=?', (owner, ident))
                return {'deleted': True}
            else:
                raise ValueError('Unknown recording action.')
            self.write(db, data)
            return self.view(data)

    def transfer(self, owner, ident, elapsed_ms) -> dict[str, Any]:
        elapsed = float(elapsed_ms)
        if not math.isfinite(elapsed) or not 0 <= elapsed <= 86400000:
            raise ValueError('Invalid upload timing.')
        with self.transaction() as db:
            data = self.row(db, owner, ident)
            data['timings']['transfer_ms'] = elapsed
            self.write(db, data)
            return {'saved': True}

    def claim(self) -> dict[str, Any]:
        with self.transaction() as db:
            now = time.time()
            if db.execute("SELECT 1 FROM recordings WHERE status IN ('decoding','loading','transcribing') AND lease_until>? LIMIT 1", (now,)).fetchone():
                return {'idle': True}
            rows = db.execute("SELECT data FROM recordings WHERE status='queued' OR (status IN ('decoding','loading','transcribing') AND lease_until<=?) ORDER BY created LIMIT 100", (now,)).fetchall()
            for row in rows:
                data = json.loads(row[0])
                if data['attempts'] >= 3:
                    data.update(status='failed', lease='', lease_until=0, error='Transcription was interrupted three times. The recording is saved; retry when the worker is available.')
                    self.write(db, data)
                    continue
                waited = max(0, now - data['stage_at']) * 1000
                data.update(status='decoding', attempts=data['attempts'] + 1, lease=uuid.uuid4().hex,
                            lease_until=now + LEASE_SECONDS, stage_at=now, percent=None, error='')
                data['timings'] = {**data['timings'], 'queue_ms': waited, 'decode_ms': 0, 'load_ms': 0, 'transcribe_ms': 0}
                self.write(db, data)
                raw = db.execute('SELECT audio FROM recordings WHERE id=?', (data['id'],)).fetchone()[0]
                return {**data, 'content': base64.b64encode(raw).decode()}
            return {'idle': True}

    def leased(self, db, ident, owner, lease):
        data = self.row(db, owner, ident)
        if not lease or lease != data['lease'] or data['lease_until'] < time.time() or data['status'] not in ACTIVE:
            raise ValueError('Transcription expired or was cancelled.')
        return data

    def progress(self, ident, owner, lease, stage, percent=None, timings=None) -> dict[str, Any]:
        if stage not in ACTIVE:
            raise ValueError('Invalid transcription stage.')
        with self.transaction() as db:
            data = self.leased(db, ident, owner, lease)
            if ACTIVE.index(stage) < ACTIVE.index(data['status']):
                raise ValueError('Transcription stage cannot move backwards.')
            if stage != data['status']:
                data['stage_at'] = time.time()
            data.update(status=stage, lease_until=time.time() + LEASE_SECONDS)
            if percent is not None:
                value = float(percent)
                if not math.isfinite(value):
                    raise ValueError('Invalid transcription progress.')
                data['percent'] = max(data['percent'] or 0, min(99, max(0, value)))
            for key, value in (timings or {}).items():
                if key in ('decode_ms', 'load_ms', 'transcribe_ms') and isinstance(value, (float, int)) and math.isfinite(value):
                    data['timings'][key] = max(0, value)
            self.write(db, data)
            return {'saved': True}

    def finish(self, ident, owner, lease, result) -> dict[str, Any]:
        with self.transaction() as db:
            data = self.leased(db, ident, owner, lease)
            if result.get('error'):
                data.update(status='failed', error=str(result['error'])[:500])
            else:
                text = result.get('text')
                if not isinstance(text, str) or not text.strip() or len(text) > 30000:
                    raise ValueError('Invalid transcription result.')
                data.update(status='completed', original_transcript=text.strip(), transcript=text.strip(), revision=1, percent=100)
            for key in ('decode_ms', 'load_ms', 'transcribe_ms'):
                value = result.get(key, data['timings'][key])
                if isinstance(value, (int, float)) and math.isfinite(value):
                    data['timings'][key] = max(0, value)
            data.update(lease='', lease_until=0)
            self.write(db, data)
            return {'saved': True}

    def delete_owner(self, owner):
        with self.transaction() as db:
            db.execute('INSERT OR IGNORE INTO deleted_owners VALUES (?)', (owner,))
            db.execute('DELETE FROM recordings WHERE owner=?', (owner,))

    def runtime_status(self) -> dict[str, Any]:
        with self.transaction() as db:
            return {k:v for k,v in self._runtime(db).items() if k!='generation'}

    def _runtime(self, db):
        row=db.execute('SELECT data FROM runtime_state WHERE id=1').fetchone()
        return json.loads(row[0]) if row else {'status':'pending','stage':'checking','message':'Local transcription is starting. Audio stays saved while setup completes.','generation':'','updated_at':time.time(),'probe_passed':False,'missing_tools':[]}

    def runtime_retry(self, owner) -> dict[str, Any]:
        with self.transaction() as db:
            self.access(db,owner);data=self._runtime(db)
            if data['status']=='unavailable':
                data.update(status='pending',stage='checking',message='Local transcription setup will retry.',updated_at=time.time())
                db.execute('INSERT OR REPLACE INTO runtime_state VALUES (1,?)',(json.dumps(data),))
            return {k:v for k,v in data.items() if k!='generation'}

    def runtime_worker(self, action, result=None, generation='') -> dict[str, Any]:
        with self.transaction() as db:
            data=self._runtime(db)
            if action=='start':
                data.update(status='preparing',stage='checking',message='Checking local transcription setup.',generation=uuid.uuid4().hex,probe_passed=False,missing_tools=[],updated_at=time.time())
            elif action=='report':
                if not generation or generation!=data['generation']:raise ValueError('Setup was replaced.')
                value=result or {}
                if value.get('status') not in ('preparing','ready','unavailable'):raise ValueError('Invalid setup state.')
                data.update({k:v for k,v in value.items() if k in ('status','stage','message','probe_passed','missing_tools','setup_ms','load_ms','transcribe_ms')})
                data['updated_at']=time.time()
            elif action!='get':raise ValueError('Invalid setup action.')
            if action!='get':db.execute('INSERT OR REPLACE INTO runtime_state VALUES (1,?)',(json.dumps(data),))
            return data
