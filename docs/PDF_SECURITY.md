# PDF processing limits

All backend PDF validation, page counting and text extraction use
`agents/pdf_safety.py`. The API never constructs a `PdfReader`. Each inspection
runs a fresh Python process with isolated imports, an environment without API
credentials, suppressed parser diagnostics, and private temporary files that
are removed on success or failure.

Limits: 10 MiB input, 50 pages, 200,000 extracted characters (50,000 for the
document helper), 1 MiB result, 10 seconds elapsed time, and 512 MiB memory.
At most two inspections run concurrently in each API/worker process; additional
requests receive a retryable busy error. Oversized text is rejected, never
silently truncated. A compressed stream is limited to 8 MiB decompressed output,
with additional page-tree and XForm bounds in pypdf 6.19.0.

Linux enforces address-space, CPU, file-size, core-dump and file-descriptor
limits. Windows uses a Job Object to enforce process memory and disallow child
processes. The parent enforces the wall-clock deadline and result size on both
platforms and terminates the worker on failure. Other platforms fail closed.
This is containment for resource exhaustion, not an arbitrary-code execution
sandbox. Client PDF previews and Tectonic compilation have separate boundaries.

Deployment must install the pinned pypdf 6.19.0 in the exact runtime used by
the API and worker, and include `agents/pdf_safety.py`. Its Python interpreter
must support isolated `-I -S` execution and OS limits. The inspected dependency
directory is obtained from trusted runtime package resolution, not PDF input.
Validate a normal upload and a rejected malformed/oversized input on that
runtime before enabling the production release. The existing attended backend
format-3 migration is still required; this change does not enable deployment.

Verification:

```sh
python tests/test_pdf_safety.py
python tests/test_fixture_provenance.py
jac check main.jac
jac run tests/agent_documents.jac
jac test tests/pdf_upload_security_tests.jac
```

The hostile-input tests include compressed streams, excessive pages/text,
encrypted/malformed documents, worker timeouts, output floods and native memory
allocations. No attack is sent to a production service.

Upstream security advisories: https://github.com/py-pdf/pypdf/security/advisories.
An OSV query for pypdf 6.19.0 returned no published advisories on 2026-10-05;
repeat the dependency scan before publication and deployment.
