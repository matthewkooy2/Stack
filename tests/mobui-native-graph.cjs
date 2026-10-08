const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),dir=path.join(root,'.jac/mobui-ios-export/_expo/static/js/ios');
const maps=fs.readdirSync(dir).filter(n=>n.endsWith('.map'));assert.ok(maps.length,'Export iOS with --source-maps before checking the native graph.');
const sources=maps.flatMap(n=>JSON.parse(fs.readFileSync(path.join(dir,n),'utf8')).sources||[]).map(n=>n.replaceAll('\\','/'));
assert.ok(sources.some(n=>n.endsWith('/mobile/prototype/platform.js')),'Native file/PDF adapter absent.');
for(const pattern of ['/mobile/prototype/platform.web.js','/mobile/prototype/date-input.web.js','/node_modules/react-native-web/','/react-native-webview/','/expo/dom/','/prototype/jobs.jsx'])assert.ok(!sources.some(n=>n.includes(pattern)),`Browser-only renderer in iOS graph: ${pattern}`);
for(const name of ['prep-motion.js','prep-session.js','prototype/app.js'])assert.ok(sources.some(n=>n.endsWith('/mobile/'+name)),name+' missing from the iOS bundle');
const coverage=require('../mobile/prototype/coverage.json');for(const row of coverage.areas.filter(r=>r.templates)){const module=row.views.replace(/^mobile\//,'/mobile/').replace(/\.jac$/,'.js');assert.ok(sources.some(n=>n.endsWith(module)),`Shared Jac view missing: ${module}`);}
fs.writeFileSync(path.join(root,'.jac/mobui-qa/native-graph.json'),JSON.stringify({status:'pass',sources:sources.length,sharedViewModules:coverage.areas.filter(r=>r.templates).length,browserRenderer:false,simulator:'not run',iPhone:'not run'},null,2));console.log(`PASS native iOS graph: ${sources.length} sources; shared Jac views present; no browser screen renderer.`);
