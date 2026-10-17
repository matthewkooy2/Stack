"""Offline resume parsing. Original implementation from functional requirements."""
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

from . import sandbox
from .structure import structure


class ParseError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class Limits:
    input_bytes: int = 10 * 1024 * 1024
    pages: int = 20
    characters: int = 250_000
    spans: int = 25_000
    output_bytes: int = 12 * 1024 * 1024
    memory_bytes: int = 1536 * 1024 * 1024
    cpu_seconds: int = 15
    timeout_seconds: float = 20

    def __post_init__(self):
        import math
        for key, value in asdict(self).items():
            if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0:
                raise ValueError(f'{key} must be finite and positive')
            if key != 'timeout_seconds' and not isinstance(value, int):
                raise ValueError(f'{key} must be an integer')


def parse_pdf(path, *, limits=Limits(), node=None):
    """Parse a local regular file into editable candidates and immutable source evidence.

    `node` is a trusted deployment configuration, never an uploaded form value.
    Limits may be lowered for tests; callers must cap aggregate request concurrency.
    """
    executable = shutil.which(node or 'node')
    if not executable:
        raise ParseError('NODE_NOT_FOUND')
    # Reject directories/devices and oversize files before copying. Read at most cap+1
    # so growth after fstat cannot cause an unbounded allocation.
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0))
        with os.fdopen(descriptor, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ParseError('NOT_REGULAR_FILE')
            if info.st_size > limits.input_bytes:
                raise ParseError('INPUT_LIMIT')
            data = source.read(limits.input_bytes + 1)
    except OSError as error:
        raise ParseError('INPUT_UNREADABLE') from error
    if len(data) > limits.input_bytes:
        raise ParseError('INPUT_LIMIT')
    if not data.startswith(b'%PDF-'):
        raise ParseError('INVALID_PDF')
    with tempfile.TemporaryDirectory(prefix='stack-resume-') as directory:
        input_path = Path(directory) / 'input.pdf'
        output_path = Path(directory) / 'output.json'
        input_path.write_bytes(data)
        input_path.chmod(0o600)
        request = json.dumps({'input': str(input_path), 'output': str(output_path),
                              'limits': asdict(limits)}).encode() + b'\n'
        command = [executable, '--max-old-space-size=192', '--v8-pool-size=1',
                   '--disable-wasm-trap-handler',
                   str(Path(__file__).resolve().parent.parent / 'extract.mjs')]
        try:
            code, diagnostic = sandbox.run(command, request, directory, limits)
        except subprocess.TimeoutExpired as error:
            raise ParseError('TIMEOUT') from error
        except OSError as error:
            raise ParseError('RESOURCE_SETUP_FAILED') from error
        if code:
            known = ('PAGE_LIMIT', 'TEXT_LIMIT', 'SPAN_LIMIT', 'OUTPUT_LIMIT',
                     'INVALID_GEOMETRY', 'PASSWORD_REQUIRED', 'INVALID_PDF', 'RUNTIME_UNSUPPORTED', 'DEPENDENCY_FAILED')
            raise ParseError(next((key for key in known if diagnostic.endswith(key)), 'WORKER_FAILED'))
        if not output_path.exists() or output_path.stat().st_size > limits.output_bytes:
            raise ParseError('OUTPUT_LIMIT')
        try:
            extracted = json.loads(output_path.read_text(encoding='utf-8'))
        except (ValueError, OSError) as error:
            raise ParseError('INVALID_OUTPUT') from error
    result = structure(extracted)
    # Bound the public review document as well as the worker's source-only JSON.
    # Match the CLI encoding, including its terminal newline, without allocating
    # another complete serialized document merely to measure its size.
    size = 1
    for chunk in json.JSONEncoder(ensure_ascii=False, indent=2).iterencode(result):
        size += len(chunk.encode('utf-8'))
        if size > limits.output_bytes:
            raise ParseError('OUTPUT_LIMIT')
    return result
