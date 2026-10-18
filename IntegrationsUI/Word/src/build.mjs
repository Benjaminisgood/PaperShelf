import { build } from 'esbuild';
import { mkdir, readFile, readdir, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
await mkdir(path.join(root, 'dist'), { recursive: true });
await build({ entryPoints: [path.join(root, 'src/server.mjs')], outfile: path.join(root, 'dist/server.mjs'), bundle: true, platform: 'node', format: 'esm', target: 'node22', legalComments: 'eof', banner: { js: "import { createRequire as paperShelfCreateRequire } from 'node:module'; const require = paperShelfCreateRequire(import.meta.url);" } });
await copyFile(path.join(root, 'node_modules/citeproc/citeproc_commonjs.js'), path.join(root, 'dist/citeproc-source.js'));
const licenses = path.join(root, 'licenses/dependencies'); await mkdir(licenses, { recursive: true });
for (const name of await readdir(path.join(root, 'node_modules'))) {
  if (name.startsWith('.') || name.startsWith('@')) continue;
  const directory = path.join(root, 'node_modules', name);
  for (const filename of await readdir(directory)) {
    if (/^(licen[sc]e|copying|notice)(\..*)?$/i.test(filename)) await copyFile(path.join(directory, filename), path.join(licenses, name + '-' + filename));
  }
}
console.log('Built dist/server.mjs with runtime dependencies. Ship dist, web, styles, locales, licenses, manifest.xml and THIRD_PARTY_NOTICES.md together.');
