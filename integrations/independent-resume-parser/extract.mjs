// Original Stack implementation. Only the supervised Python entry point is public.
// Wait for the supervisor's job/memory controls before importing or reading input.
import fs from 'node:fs';
import readline from 'node:readline';
const control = readline.createInterface({ input: process.stdin });
const request = await new Promise(resolve => control.once('line', resolve));
control.close();
process.stdin.destroy();
let stage = 'runtime';
try {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 13)) throw new Error('RUNTIME_UNSUPPORTED');
  const { input, output, limits } = JSON.parse(request);
  const { getDocument, Util } = await import('pdfjs-dist/legacy/build/pdf.mjs');
  stage = 'pdf';
  const task = getDocument({
    data: new Uint8Array(fs.readFileSync(input)), verbosity: 0,
    isEvalSupported: false, useWasm: false, useWorkerFetch: false,
    disableFontFace: true, useSystemFonts: false, enableXfa: false,
    isOffscreenCanvasSupported: false, isImageDecoderSupported: false,
    stopAtErrors: true, maxImageSize: 0,
  });
  const pdf = await task.promise;
  if (pdf.numPages > limits.pages) throw new Error('PAGE_LIMIT');
  let characters = 0, count = 0;
  const pages = [];
  for (let number = 1; number <= pdf.numPages; number++) {
    const page = await pdf.getPage(number);
    const viewport = page.getViewport({ scale: 1 });
    const reader = page.streamTextContent({ disableNormalization: true }).getReader();
    const spans = [];
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      for (const item of chunk.value.items) {
        if (typeof item.str !== 'string') continue;
        characters += item.str.length;
        if (characters > limits.characters) throw new Error('TEXT_LIMIT');
        if (++count > limits.spans) throw new Error('SPAN_LIMIT');
        const t = Util.transform(viewport.transform, item.transform);
        const box = [t[4], t[5], item.width, item.height];
        if (!box.every(Number.isFinite)) throw new Error('INVALID_GEOMETRY');
        spans.push({ id: `p${number}s${spans.length}`, text: item.str,
          bbox: box, direction: item.dir, endOfLine: item.hasEOL });
      }
    }
    pages.push({ number, width: viewport.width, height: viewport.height, spans });
    page.cleanup();
  }
  const result = JSON.stringify({ pages });
  if (Buffer.byteLength(result) > limits.output_bytes) throw new Error('OUTPUT_LIMIT');
  fs.writeFileSync(output, result, { flag: 'wx', mode: 0o600 });
  await task.destroy();
} catch (error) {
  // Do not expose PDF content, file paths, or dependency diagnostics to callers.
  const allowed = new Set(['PAGE_LIMIT', 'TEXT_LIMIT', 'SPAN_LIMIT', 'OUTPUT_LIMIT', 'INVALID_GEOMETRY', 'RUNTIME_UNSUPPORTED']);
  const code = allowed.has(error.message) ? error.message :
    stage === 'runtime' ? 'DEPENDENCY_FAILED' : error.name === 'PasswordException' ? 'PASSWORD_REQUIRED' : 'INVALID_PDF';
  process.stderr.write(code);
  process.exitCode = 2;
}
