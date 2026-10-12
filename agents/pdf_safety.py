"""Bounded PDF inspection in a disposable process; never parse in the API.

This contains resource exhaustion, not arbitrary code execution. PDF.js/UI
rendering and the LaTeX compiler have separate security boundaries.
"""
from __future__ import annotations

import base64
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

MAX_INPUT = 10 * 1024 * 1024
MAX_PAGES = 50
MAX_TEXT = 200_000
MAX_OUTPUT = 1024 * 1024
MAX_SPANS = 8000
MAX_DIMENSION = 14400
MEMORY_BYTES = 512 * 1024 * 1024
TIMEOUT_SECONDS = 10
_slots = threading.BoundedSemaphore(2)
_job_handle = None


class _Rejected(ValueError):
    pass


def _worker_limits():
    """Install OS limits before importing pypdf or reading hostile input."""
    global _job_handle
    if sys.platform == "linux":
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (MEMORY_BYTES, MEMORY_BYTES))
        cpu = math.ceil(TIMEOUT_SECONDS)
        resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))
        resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_OUTPUT, MAX_OUTPUT))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
    elif os.name == "nt":
        import ctypes
        from ctypes import wintypes as w

        class BASIC(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                        ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", w.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", w.DWORD), ("Affinity", ctypes.c_size_t),
                        ("PriorityClass", w.DWORD), ("SchedulingClass", w.DWORD)]

        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                         "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class EXTENDED(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", BASIC), ("IoInfo", IO),
                        ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        kernel.CreateJobObjectW.restype = w.HANDLE
        kernel.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        kernel.SetInformationJobObject.restype = w.BOOL
        kernel.GetCurrentProcess.restype = w.HANDLE
        kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        kernel.AssignProcessToJobObject.restype = w.BOOL
        kernel.CloseHandle.argtypes = [w.HANDLE]
        handle = kernel.CreateJobObjectW(None, None)
        if not handle:
            raise OSError("Cannot create PDF resource limits")
        limits = EXTENDED()
        # JOB_OBJECT_LIMIT_PROCESS_MEMORY | ACTIVE_PROCESS | KILL_ON_JOB_CLOSE
        limits.BasicLimitInformation.LimitFlags = 0x100 | 0x8 | 0x2000
        limits.BasicLimitInformation.ActiveProcessLimit = 1
        limits.ProcessMemoryLimit = MEMORY_BYTES
        if not kernel.SetInformationJobObject(handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            kernel.CloseHandle(handle)
            raise OSError("Cannot configure PDF resource limits")
        if not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess()):
            kernel.CloseHandle(handle)
            raise OSError("Cannot attach PDF resource limits")
        # Keep this handle alive until process exit.
        _job_handle = handle
    else:
        raise OSError("PDF processing requires Linux or Windows resource limits")


def _kill(process):
    if process.poll() is not None:
        process.wait()
        return
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    elif process.poll() is None:
        process.kill()
    process.wait()


def _run_worker(command, data, *, timeout=TIMEOUT_SECONDS):
    # File-backed output prevents communicate() from buffering unlimited output.
    with tempfile.TemporaryDirectory(prefix="stack-pdf-") as directory:
        root = Path(directory)
        incoming, outgoing = root / "input.pdf", root / "result.json"
        incoming.write_bytes(data)
        incoming.chmod(0o600)
        environment = {key: value for key, value in os.environ.items()
                       if key in {"PATH", "SystemRoot", "WINDIR", "TEMP", "TMP", "LANG"}}
        with incoming.open("rb") as source, outgoing.open("w+b") as output:
            process = subprocess.Popen(command, stdin=source, stdout=output,
                                       stderr=subprocess.DEVNULL, cwd=directory,
                                       env=environment, start_new_session=os.name == "posix")
            deadline = time.monotonic() + timeout
            try:
                while process.poll() is None:
                    if time.monotonic() >= deadline:
                        raise ValueError("PDF processing took too long. Please export a simpler PDF.")
                    if os.fstat(output.fileno()).st_size > MAX_OUTPUT:
                        raise ValueError("PDF output exceeds the safe processing limit.")
                    time.sleep(0.02)
                if process.returncode:
                    raise ValueError("PDF processing failed or exceeded its resource limits.")
                output.seek(0)
                result = output.read(MAX_OUTPUT + 1)
                if len(result) > MAX_OUTPUT:
                    raise ValueError("PDF output exceeds the safe processing limit.")
                return result
            finally:
                _kill(process)


def _python_executable():
    # Embedded Jac reports the jac launcher as sys.executable. Its sys.prefix
    # identifies the actual bundled Python runtime; ordinary venvs work too.
    names = ["python.exe"] if os.name == "nt" else [
        f"bin/python{sys.version_info.major}.{sys.version_info.minor}", "bin/python3", "bin/python"]
    for name in names:
        candidate = Path(sys.prefix) / name
        if candidate.is_file():
            return str(candidate.resolve())
    candidate = Path(sys.executable)
    if candidate.is_file() and candidate.name.lower().startswith(("python", "pypy")):
        return str(candidate.resolve())
    raise ValueError("An isolated Python runtime is required for PDF processing.")


def inspect_pdf(data: bytes, extract: bool = False, max_chars: int = MAX_TEXT) -> dict:
    return _inspect(data, "extract" if extract else "validate", max_chars)


def inspect_spans(data: bytes, max_chars: int = MAX_TEXT) -> dict:
    """Positioned text fragments for structured resume parsing, from the same bounded lane.

    Returns {"pages": n, "text": "", "layout": [{"width", "height", "spans": [[x, y, w, h, text]]}]}.
    Coordinates are points with a top-left origin; y is the text baseline. Widths come from
    the PDF font when pypdf can read it and are otherwise estimated from the font size.
    """
    return _inspect(data, "spans", max_chars)


def _inspect(data: bytes, mode: str, max_chars: int) -> dict:
    extract = mode != "validate"
    if not isinstance(data, bytes) or len(data) > MAX_INPUT or not data.startswith(b"%PDF-"):
        raise ValueError("Choose a valid PDF, 10 MB or smaller.")
    if not isinstance(max_chars, int) or not 1 <= max_chars <= MAX_TEXT:
        raise ValueError("Invalid PDF text limit.")
    if not _slots.acquire(blocking=False):
        raise ValueError("PDF processing is busy. Please try again shortly.")
    try:
        dependency = importlib.util.find_spec("pypdf")
        if dependency is None or not dependency.origin:
            raise ValueError("PDF processing is unavailable.")
        # -I -S skips cwd, PYTHONPATH, site hooks and unrelated API dependencies.
        # The package directory is obtained from trusted runtime configuration.
        packages = str(Path(dependency.origin).resolve().parent.parent)
        command = [_python_executable(), "-I", "-S", str(Path(__file__).resolve()),
                   packages, mode, str(max_chars)]
        encoded = _run_worker(command, data, timeout=TIMEOUT_SECONDS)
        try:
            result = json.loads(encoded)
        except (ValueError, UnicodeError):
            raise ValueError("PDF processing returned invalid output.") from None
        if not isinstance(result, dict):
            raise ValueError("PDF processing returned invalid output.")
        if result.get("error"):
            raise ValueError(str(result["error"])[:300])
        if (type(result.get("pages")) is not int or not 1 <= result["pages"] <= MAX_PAGES
                or not isinstance(result.get("text"), str) or len(result["text"]) > max_chars):
            raise ValueError("PDF processing returned invalid output.")
        if mode == "spans" and not _valid_layout(result.get("layout"), result["pages"], max_chars):
            raise ValueError("PDF processing returned invalid output.")
        return result
    finally:
        _slots.release()


def _valid_layout(layout, pages: int, max_chars: int) -> bool:
    """The worker is trusted to be bounded, but its output is still checked at the boundary."""
    if not isinstance(layout, list) or len(layout) != pages:
        return False
    count = characters = 0
    for page in layout:
        if not isinstance(page, dict) or not isinstance(page.get("spans"), list):
            return False
        if not all(type(page.get(key)) in (int, float) and 0 < page[key] <= MAX_DIMENSION * 10
                   for key in ("width", "height")):
            return False
        for span in page["spans"]:
            if (not isinstance(span, list) or len(span) != 5 or not isinstance(span[4], str)
                    or not all(type(v) in (int, float) and math.isfinite(v) for v in span[:4])):
                return False
            count += 1
            characters += len(span[4])
        if count > MAX_SPANS or characters > max_chars:
            return False
    return True


def inspect_file(path, extract: bool = False, max_chars: int = MAX_TEXT) -> dict:
    with Path(path).open("rb") as stream:
        data = stream.read(MAX_INPUT + 1)
    return inspect_pdf(data, extract, max_chars)


def extract_encoded(content: str, max_chars: int = MAX_TEXT) -> str:
    if len(content) > 13_981_016:
        raise ValueError("PDF must be 10 MB or smaller.")
    try:
        data = base64.b64decode(content, validate=True)
    except (ValueError, UnicodeError):
        raise ValueError("Invalid PDF encoding.") from None
    text = inspect_pdf(data, True, max_chars)["text"]
    if not text.strip():
        raise ValueError("This PDF has no readable text. Add verified facts or upload a text-based PDF.")
    return text


def _collect_spans(reader, max_chars):
    """Text fragments with baseline positions, collected through pypdf's text visitor."""
    fonts = {}

    def width_of(font_dict, text, size):
        # pypdf's font helper is internal API; the pin in jac.toml makes it stable, and any
        # failure falls back to a plain per-character estimate rather than failing the parse.
        key = id(font_dict)
        if key not in fonts:
            fonts[key] = None
            if font_dict is not None and len(fonts) <= 256:
                try:
                    from pypdf._font import Font
                    fonts[key] = Font.from_font_resource(font_dict)
                except Exception:
                    fonts[key] = None
        font = fonts[key]
        if font is not None:
            try:
                return font.get_text_width(text) / 1000.0 * size
            except Exception:
                pass
        return 0.5 * size * len(text)

    pages, total, count = [], 0, 0
    for page in reader.pages:
        if int(page.rotation or 0) % 360:
            raise _Rejected("Rotated PDF pages are not supported for structured extraction.")
        box = page.mediabox
        left, bottom = float(box.left), float(box.bottom)
        width, height = abs(float(box.width)), abs(float(box.height))
        unit = float(page.get("/UserUnit", 1) or 1)
        if not (0 < unit <= 10 and 0 < width <= MAX_DIMENSION and 0 < height <= MAX_DIMENSION):
            raise _Rejected("This PDF page size is not supported.")
        spans = []

        def visit(text, cm, tm, font_dict, font_size, spans=spans, left=left, bottom=bottom,
                  height=height, unit=unit):
            nonlocal total, count
            # pypdf appends a newline when the operator ended a text line.
            value = " ".join(text.rstrip("\r\n").splitlines()) if isinstance(text, str) else ""
            if not value:
                return
            total += len(value)
            count += 1
            if count > MAX_SPANS or total > max_chars:
                raise _Rejected("PDF text exceeds the safe processing limit.")
            a, b, c, d, e, f = [float(v) for v in tm]
            ca, cb, cc, cd, ce, cf = [float(v) for v in cm]
            x = e * ca + f * cc + ce
            y = e * cb + f * cd + cf
            horizontal = math.hypot(a * ca + b * cc, a * cb + b * cd) * unit
            vertical = math.hypot(c * ca + d * cc, c * cb + d * cd) * unit
            size = abs(float(font_size or 0)) or 1.0
            span = [round((x - left) * unit, 2), round((height - (y - bottom)) * unit, 2),
                    round(width_of(font_dict, value, size) * horizontal, 2), round(size * vertical, 2), value]
            if all(math.isfinite(v) for v in span[:4]):
                spans.append(span)

        page.extract_text(visitor_text=visit)
        pages.append({"width": round(width * unit, 2), "height": round(height * unit, 2), "spans": spans})
    return pages


def _worker():
    try:
        _worker_limits()
        sys.path.insert(0, sys.argv[1])
        from pypdf import PdfReader
        # Set a stricter decompression bound as an additional layer. OS limits
        # remain necessary for page trees, fonts and other parser operations.
        from pypdf import overwrite_configuration
        overwrite_configuration(
            maximum_declared_stream_length=MAX_INPUT,
            zlib_maximum_output_length=8 * 1024 * 1024,
            array_based_stream_maximum_output_length=8 * 1024 * 1024,
            lzw_maximum_output_length=8 * 1024 * 1024,
            run_length_maximum_output_length=8 * 1024 * 1024,
            page_tree_maximum_entries=5000,
            page_tree_maximum_depth=50,
            xform_maximum_invocations_per_extraction=1000,
            jbig2dec_binary=None,
        )
        reader = PdfReader(sys.stdin.buffer)
        if reader.is_encrypted:
            raise _Rejected("Choose an unencrypted PDF.")
        pages = len(reader.pages)
        if not 1 <= pages <= MAX_PAGES:
            raise _Rejected("PDF must contain between 1 and 50 pages.")
        parts, total = [], 0
        max_chars = int(sys.argv[3])
        if sys.argv[2] == "spans":
            result = {"pages": pages, "text": "", "layout": _collect_spans(reader, max_chars)}
            encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            if len(encoded) > MAX_OUTPUT:
                raise _Rejected("PDF output exceeds the safe processing limit.")
            sys.stdout.buffer.write(encoded)
            return
        if sys.argv[2] == "extract":
            for page in reader.pages:
                text = page.extract_text() or ""
                total += len(text) + (1 if parts else 0)
                if total > max_chars:
                    raise _Rejected("PDF text exceeds the safe processing limit.")
                parts.append(text)
        result = {"pages": pages, "text": "\n".join(parts)}
    except _Rejected as error:
        # Only our controlled messages leave the worker; parser exceptions can
        # contain private document text or arbitrarily long diagnostics.
        result = {"error": str(error)[:300]}
    except Exception:
        result = {"error": "This PDF could not be opened or exceeded its resource limits."}
    encoded = json.dumps(result, ensure_ascii=False).encode("utf-8")
    if len(encoded) > MAX_OUTPUT:
        encoded = b'{"error":"PDF output exceeds the safe processing limit."}'
    sys.stdout.buffer.write(encoded)


if __name__ == "__main__":
    _worker()
