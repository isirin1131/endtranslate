import { build } from 'esbuild';
import { cp, mkdir, readFile, writeFile, readdir, stat, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const here = fileURLToPath(new URL('.', import.meta.url));
const output = fileURLToPath(new URL('../../Sources/EndTranslate/Resources/Renderer/', import.meta.url));
const modules = join(here, 'node_modules');
const vendor = join(output, 'vendor');
const extensions = ['begingroup', 'cancel', 'enclose', 'mathtools', 'braket', 'boldsymbol', 'color'];
await rm(vendor, { recursive: true, force: true });
await mkdir(join(vendor, 'mathjax/input/tex/extensions'), { recursive: true });
await cp(join(modules, '@mathjax/mathjax-tex-font/tex-mml-svg-mathjax-tex.js'), join(vendor, 'mathjax/mathjax.js'));
for (const name of extensions) {
  await cp(join(modules, `mathjax/input/tex/extensions/${name}.js`), join(vendor, `mathjax/input/tex/extensions/${name}.js`));
}
await build({
  entryPoints: [join(here, 'renderer.mjs')], outfile: join(output, 'renderer.js'),
  bundle: true, minify: true, format: 'iife', target: 'safari17', legalComments: 'eof'
});

const libraries = ['mathjax', '@mathjax/mathjax-tex-font', 'markdown-it', 'mdurl', 'uc.micro', 'linkify-it', 'punycode.js', 'entities'];
const versions = {};
let notices = 'Third-party components bundled with EndTranslate\n\n';
for (const name of libraries) {
  const root = join(modules, name);
  const info = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  versions[name] = info.version;
  const license = (await readdir(root)).find(file => /^license(?:[.-]|$)/i.test(file));
  // The font package declares Apache-2.0 but omits the license file from its tarball.
  const licensePath = license ? join(root, license) : join(modules, 'mathjax/LICENSE');
  notices += `${name} ${info.version} (${info.license})\n${'='.repeat(72)}\n${await readFile(licensePath, 'utf8')}\n\n`;
}
await writeFile(join(vendor, 'THIRD_PARTY_NOTICES.txt'), notices);
const hashes = {};
async function hashFiles(directory, prefix = '') {
  for (const name of (await readdir(directory)).sort()) {
    const relative = prefix + name;
    if (name === 'manifest.json') continue;
    const path = join(directory, name);
    const info = await stat(path);
    if (info.isDirectory()) await hashFiles(path, relative + '/');
    else hashes[relative] = createHash('sha256').update(await readFile(path)).digest('hex');
  }
}
await hashFiles(output);
await writeFile(join(output, 'manifest.json'), JSON.stringify({ versions, sha256: hashes }, null, 2) + '\n');
console.log(`Bundled ${Object.keys(hashes).length} local renderer files.`);
