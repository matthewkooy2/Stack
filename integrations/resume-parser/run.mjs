// Node adaptation of OpenResume read-pdf.ts. AGPL-3.0-only, modified 2026-09-29.
import { getDocument } from 'pdfjs-dist/legacy/build/pdf.mjs';
import parser from '../../.jac/resume-parser.cjs';

try {
  const chunks = []; let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 10485760) throw new Error('PDF exceeds 10 MB.');
    chunks.push(chunk);
  }
  const loading = getDocument({ data: new Uint8Array(Buffer.concat(chunks)), isEvalSupported: false, useSystemFonts: true, disableFontFace: true, useWorkerFetch: false, verbosity: 0 });
  const pdf = await loading.promise;
  if (pdf.numPages > 20) throw new Error('Resume parsing supports up to 20 pages.');
  const items = [];
  for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
    const page = await pdf.getPage(pageNumber);
    const content = await page.getTextContent();
    await page.getOperatorList();
    for (const item of content.items) {
      if (!('str' in item) || (!item.hasEOL && !item.str.trim())) continue;
      const { str, transform, fontName, dir, ...rest } = item;
      let originalFont = fontName;
      try { originalFont = page.commonObjs.get(fontName).name; } catch {}
      items.push({ ...rest, text: str.replace(/-\u00ad\u2010/g, '-'), x: transform[4], y: transform[5], fontName: originalFont || '' });
      if (items.length > 20000) throw new Error('Resume has too many text elements.');
    }
    page.cleanup();
  }
  await loading.destroy();
  if (!items.some(item => item.text.trim())) throw new Error('No readable text. Export a text PDF; scanned resumes need OCR.');
  const result = parser.parse(items);
  const output = JSON.stringify(result);
  if (Buffer.byteLength(output) > 524288) throw new Error('Extracted resume exceeds the review limit.');
  process.stdout.write(output);
} catch (error) {
  process.stdout.write(JSON.stringify({ error: error.message || 'This PDF could not be parsed.' }));
  process.exitCode = 1;
}
