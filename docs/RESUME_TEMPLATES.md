# Resume templates

The iOS format picker offers six designs: Jake's Resume, Awesome-CV, Bill Ryan's
Elegant Resume, Sourabh Bajaj's Resume, Deedy Resume (OpenFonts), and Jan Kuster's
Classic CV. The last choice is the Classic design from the latexcv collection.
Legacy Stack Classic remains supported for saved documents and older clients,
but is no longer offered by the iOS picker.

The five imported designs retain their upstream preambles/classes and adapt
Stack's entry and bullet commands to those styles. Structured details and reviewed
import records both use the chosen design. Records retain their confirmed text
and order; no employers, dates, qualifications or fields are inferred to fit a
layout. Deedy divides sections between asymmetric columns and supports page
breaks. PDF output uses the existing isolated Tectonic compiler and document text
checks. Editable DOCX exports retain the reviewed paragraphs and use the existing
simple Word layout; they do not reproduce the LaTeX design.

`agents/templates/upstream.json` records immutable source revisions and bundled
files. Awesome-CV is pinned to the XeTeX-compatible v1.6.1 class before its LuaLaTeX
migration; the current upstream class cannot run in Tectonic. Bill Ryan uses
bundled TeX Gyre Termes, including small caps, rather than Fontin. Deedy uses its
bundled Lato and Raleway fonts; Jan Kuster also bundles Raleway so the XeTeX build
uses its intended sans-serif typography. Other fonts/packages come from Tectonic's bundle.
Template and font licenses accompany the sources; template notices are also
embedded in each main `.tex` file. See `THIRD_PARTY_NOTICES.txt`.

Use the existing `scripts/warm-resume-templates.jac` to download compiler packages
and compile the built-in layouts before serving them. Updating the picker requires
a native build; updating rendering requires deploying the backend and assets
together. Swift structure checks on Windows do not establish native acceptance;
build and exercise selection, preview, save/reopen and tailoring on the Mac/iPhone.
