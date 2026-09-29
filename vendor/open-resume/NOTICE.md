# OpenResume Attribution

Source: https://github.com/xitanggg/open-resume
Revision: `4f8255a2c763479837f69f1dccf2a3338730cd79`
Copyright: OpenResume contributors, including Xitang Gong.
License: GNU Affero General Public License version 3 (see LICENSE).
Provided without warranty, including merchantability or fitness for a purpose.

Stack vendors the parser, its types, and deep-clone helper. Parser algorithms are
unmodified. `lib/redux/resumeSlice.ts` is reduced to the parser's default skills.
Stack's `integrations/resume-parser/run.mjs` adapts the PDF reader for local Node
execution with modern PDF.js, limits, and JSON IO. Changes dated 2026-09-29.
The upstream browser reader and parser tests remain as source references.

Stack's adapter, review integration, and modifications are available under AGPL-3.0.
Anyone distributing or hosting this combined integration must fulfill the license's
corresponding-source requirements for the covered work, not just this directory.
Before distribution or hosted deployment, provide the complete corresponding
source for the actual deployed version and its build instructions. See
`docs/RESUME_PARSER.md`. No claim is made that a link to upstream alone satisfies
those obligations.
