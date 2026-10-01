import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

await build({
  entryPoints: [fileURLToPath(new URL('parser.ts', import.meta.url))],
  outfile: fileURLToPath(new URL('../../.jac/resume-parser.cjs', import.meta.url)),
  bundle: true, platform: 'node', format: 'cjs',
  alias: { lib: fileURLToPath(new URL('../../vendor/open-resume/lib', import.meta.url)) },
  banner: { js: '// OpenResume-derived parser. AGPL-3.0-only. See vendor/open-resume/LICENSE and NOTICE.md.' }
});
