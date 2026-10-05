# Resume parsing is temporarily unavailable

The OpenResume implementation, adapter, review UI, and upstream sample PDF have
been removed. PDF uploads, private storage, previews and account exports remain
available. New uploads do not queue detail extraction. Existing PDF tickets are
cancelled when claimed, and late worker results cannot update resume details.
Existing user data and confirmed facts are preserved.

PDF-only scoring, PDF detail review and PDF parser checks on tailored documents
are paused. Uploaded LaTeX can still be compiled, scored and tailored. Existing
confirmed details can still populate a built-in template; new PDFs cannot supply
those details until an independently implemented parser and review flow land.

The replacement is being built separately from functional requirements, using
permissively licensed dependencies and original synthetic fixtures. It must not
copy or translate the retired implementation or its review UI.

Removing files in the current version does not remove their earlier copies from
Git branches, history, pull requests, release artifacts or installed services.
Review those separately before publishing. This change does not select a license
for Stack's original code or resolve obligations for previous distributions.

Backend release format 3 requires an attended host migration before deployment.
See [the deployment guide](AUTOMATIC_BACKEND_DEPLOYMENT.md).
