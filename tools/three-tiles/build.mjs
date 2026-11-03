import { build } from 'esbuild';
// Only the bare "three" import stays external, because the page loads it through its import map.
// Three's example loaders are bundled in, since the overlay serves no other files.
const keepBareThreeExternal = { name: 'bare-three-external', setup(b) { b.onResolve({ filter: /^three$/ }, () => ({ path: 'three', external: true })); } };
await build({ entryPoints: ['entry.js'], bundle: true, format: 'esm', minify: true, outfile: 'out/three-tiles.js', plugins: [keepBareThreeExternal], legalComments: 'none' });
