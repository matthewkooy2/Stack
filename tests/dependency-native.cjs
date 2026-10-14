// Exercise the Expo -> xcode -> uuid consumer after the transitive override.
// Run after npm ci in native/ with: node tests/dependency-native.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {createRequire} = require('node:module');
const path = require('node:path');
const nativeRequire = createRequire(path.resolve(__dirname, '../native/package.json'));
const xcode = nativeRequire('xcode');
const project = xcode.project('synthetic.xcodeproj/project.pbxproj');
project.hash = {project: {objects: {}}};
const ids = Array.from({length: 100}, () => project.generateUuid());
assert.equal(new Set(ids).size, ids.length);
assert.ok(ids.every(id => /^[A-F0-9]{24}$/.test(id)));
console.log('Expo xcode UUID consumer: 100 unique compatible project identifiers.');

// Optionally verify the actual Metro export, including indexed source maps.
// node tests/dependency-native.cjs /path/to/expo-export
if (process.argv[2]) {
  const exportDirectory = path.resolve(process.argv[2]);
  const maps = [];
  function walk(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(filename);
      else if (entry.name.endsWith('.map')) maps.push(filename);
    }
  }
  function sources(map) {
    return [...(map.sources || []), ...(map.sections || []).flatMap(section => sources(section.map))];
  }
  walk(exportDirectory);
  assert.ok(maps.length, 'Export must include source maps for dependency reachability checks.');
  const bundled = maps.flatMap(filename => sources(JSON.parse(fs.readFileSync(filename, 'utf8'))));
  assert.ok(bundled.length, 'Export source maps must list bundled modules.');
  const exposed = bundled.filter(source => /(^|\/)node_modules\/(braces|node-forge)(\/|$)/.test(source.replaceAll('\\', '/')));
  assert.deepEqual(exposed, [], 'Unpatched build-tool packages must not enter the exported app bundle.');
  console.log(`App export: ${bundled.length} sources, no braces or node-forge in the bundle.`);
}
