"""Hostile PDF/resource regressions using synthetic inputs; no service needed."""
import base64
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agents import pdf_safety as pdf
from pypdf import PdfReader, PdfWriter
from pypdf.generic import EncodedStreamObject, NameObject

PDF = (Path(__file__).parent / "fixtures/synthetic-resume.pdf").read_bytes()


def document(pages=1, encrypted=False, stream=None):
    writer = PdfWriter()
    for _ in range(pages):
        page = writer.add_blank_page(612, 792) if stream is None else writer.add_page(PdfReader(io.BytesIO(PDF)).pages[0])
        if stream is not None:
            page[NameObject("/Contents")] = writer._add_object(stream)
    if encrypted:
        writer.encrypt("synthetic-password")
    result = io.BytesIO()
    writer.write(result)
    return result.getvalue()


class PdfSafety(unittest.TestCase):
    def test_resume_fixture_has_valid_cross_reference_offsets(self):
        self.assertEqual(len(PdfReader(io.BytesIO(PDF), strict=True).pages), 1)

    def test_text_and_page_count_preserved(self):
        result = pdf.inspect_pdf(PDF, True)
        self.assertEqual(result["pages"], 1)
        self.assertIn("alex@example.invalid", result["text"])
        self.assertIn("Python, TypeScript", result["text"])

    def test_parent_never_constructs_reader(self):
        with patch("pypdf.PdfReader", side_effect=AssertionError("API parsed PDF")):
            self.assertEqual(pdf.inspect_pdf(PDF)["pages"], 1)

    def test_file_and_encoded_entry_points(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resume.pdf"
            path.write_bytes(PDF)
            self.assertIn("Alex Example", pdf.inspect_file(path, True)["text"])
        self.assertIn("Alex Example", pdf.extract_encoded(base64.b64encode(PDF).decode()))

    def test_validation_accepts_image_only_or_blank_pdf(self):
        raw = document()
        self.assertEqual(pdf.inspect_pdf(raw)["pages"], 1)
        with self.assertRaisesRegex(ValueError, "no readable text"):
            pdf.extract_encoded(base64.b64encode(raw).decode())

    def test_encrypted_zero_and_excessive_pages_rejected(self):
        for raw, message in [(document(encrypted=True), "unencrypted"),
                             (document(0), "1 and 50"), (document(51), "1 and 50")]:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                pdf.inspect_pdf(raw)

    def test_bad_header_encoding_and_size_rejected_before_spawn(self):
        with patch.object(pdf, "_run_worker", side_effect=AssertionError("spawned")):
            for raw in (b"not pdf", b"%PDF-" + b"x" * pdf.MAX_INPUT):
                with self.assertRaises(ValueError):
                    pdf.inspect_pdf(raw)
            for encoded in ("%%%", "A" * 13_981_017):
                with self.assertRaises(ValueError):
                    pdf.extract_encoded(encoded)

    def test_malformed_pdf_has_bounded_generic_error(self):
        with self.assertRaises(ValueError) as error:
            pdf.inspect_pdf(b"%PDF-1.4\nPRIVATE_SENTINEL_NOT_A_PDF")
        self.assertNotIn("PRIVATE_SENTINEL", str(error.exception))
        self.assertLess(len(str(error.exception)), 301)

    def test_excessive_text_rejected_instead_of_silent_truncation(self):
        with self.assertRaisesRegex(ValueError, "text exceeds"):
            pdf.inspect_pdf(PDF, True, 5)

    def test_compressed_stream_is_bounded(self):
        stream = EncodedStreamObject()
        stream[NameObject("/Filter")] = NameObject("/FlateDecode")
        stream._data = zlib.compress(b"BT (" + b"a" * (12 * 1024 * 1024) + b") Tj ET")
        started = time.monotonic()
        with self.assertRaises(ValueError):
            pdf.inspect_pdf(document(stream=stream), True)
        self.assertLess(time.monotonic() - started, 15)

    def test_parallel_processing_has_backpressure(self):
        pdf._slots.acquire()
        pdf._slots.acquire()
        try:
            with self.assertRaisesRegex(ValueError, "busy"):
                pdf.inspect_pdf(PDF)
        finally:
            pdf._slots.release()
            pdf._slots.release()
        self.assertEqual(pdf.inspect_pdf(PDF)["pages"], 1)

    def test_timeout_kills_worker_and_cleans_files(self):
        directories = []
        real = tempfile.TemporaryDirectory
        def tracked(*args, **kwargs):
            item = real(*args, **kwargs)
            directories.append(Path(item.name))
            return item
        with patch.object(pdf.tempfile, "TemporaryDirectory", side_effect=tracked):
            with self.assertRaisesRegex(ValueError, "too long"):
                pdf._run_worker([sys.executable, "-I", "-S", "-c", "while True: pass"], PDF, timeout=0.3)
        self.assertTrue(directories)
        self.assertTrue(all(not path.exists() for path in directories))

    def test_stdout_flood_is_bounded(self):
        command = [sys.executable, "-I", "-S", "-c",
                   "import os;\nwhile True: os.write(1,b'x'*65536)"]
        with self.assertRaisesRegex(ValueError, "output exceeds"):
            pdf._run_worker(command, PDF, timeout=5)

    def test_invalid_worker_result_rejected_and_slot_released(self):
        for result in (b"not json", b"[]", json.dumps({"pages": 999, "text": ""}).encode()):
            with patch.object(pdf, "_run_worker", return_value=result), self.assertRaises(ValueError):
                pdf.inspect_pdf(PDF)
        self.assertEqual(pdf.inspect_pdf(PDF)["pages"], 1)

    def test_os_memory_limit_blocks_native_allocation(self):
        # A heap-only limit or text slice would not contain this allocation.
        module = str(Path(pdf.__file__).resolve().parent)
        code = (f"import sys; sys.path.insert(0,{module!r}); import pdf_safety as p; "
                "p._worker_limits(); print('LIMITS_READY',flush=True); "
                "bytearray(p.MEMORY_BYTES*2)")
        result = subprocess.run([sys.executable, "-I", "-S", "-c", code],
                                capture_output=True, timeout=10)
        self.assertIn(b"LIMITS_READY", result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_unsupported_platform_fails_closed(self):
        with patch.object(pdf.sys, "platform", "unsupported"), patch.object(pdf.os, "name", "posix"):
            with self.assertRaises(OSError):
                pdf._worker_limits()

    def test_embedded_jac_launcher_uses_real_python_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = root / ("python.exe" if pdf.os.name == "nt" else
                               f"bin/python{sys.version_info.major}.{sys.version_info.minor}")
            expected.parent.mkdir(parents=True, exist_ok=True)
            expected.touch()
            with patch.object(pdf.sys, "prefix", directory), patch.object(pdf.sys, "executable", "jac"):
                self.assertEqual(pdf._python_executable(), str(expected.resolve()))


if __name__ == "__main__":
    unittest.main()
