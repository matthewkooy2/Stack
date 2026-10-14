// The app's list of callable account functions equals the gateway's published list, and every function the live
// screens call by name is on it (so a typo or a removed endpoint fails here, not on a phone).
//   node tests/live-contract.cjs
const assert=require('node:assert/strict'),fs=require('fs'),path=require('path');
(async()=>{
 const root=path.resolve(__dirname,'..');
 const gateway=fs.readFileSync(path.join(root,'agents/gateway.jac'),'utf8');
 const published=new Set(gateway.match(/PERSONAL = `set\(\s*'''([\s\S]*?)'''\.split\(\)/)[1].split(/\s+/).filter(Boolean));
 const {FEATURE_RPCS}=await import('data:text/javascript;base64,'+fs.readFileSync(path.join(root,'mobile/feature-rpcs.js')).toString('base64'));
 assert.deepEqual([...FEATURE_RPCS].sort(),[...published].sort(),'feature-rpcs.js must match the gateway PERSONAL list');
 const used=new Set();
 for(const dir of ['mobile/prototype','mobile']){
  for(const file of fs.readdirSync(path.join(root,dir)).filter(n=>n.endsWith('.js'))){
   const text=fs.readFileSync(path.join(root,dir,file),'utf8');
   for(const m of text.matchAll(/\b(?:call|mutate|rpc)\(\s*'([a-z_]+)'/g))used.add(m[1]);
   for(const m of text.matchAll(/\bact\(\s*'([a-z]+_[a-z_]+)'/g))used.add(m[1]);
   for(const m of text.matchAll(/\bupload\(\s*'([a-z_]+)'/g))used.add(m[1]);
  }
 }
 const authOnly=new Set(['auth_google_status','auth_google_recover','agent_admission','agent_accept_invite']);
 const missing=[...used].filter(n=>!published.has(n)&&!authOnly.has(n));
 assert.deepEqual(missing,[],'screens call functions the gateway does not publish: '+missing);
 console.log('PASS live contract: '+published.size+' published functions; '+used.size+' called by name, all published.');
})().catch(e=>{console.error(e.message);process.exit(1);});
