const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const root=path.resolve(__dirname,'..'),bundled=JSON.parse(fs.readFileSync(path.join(root,'mobile/prep-catalog.json'),'utf8'));
 const source=fs.readFileSync(path.join(root,'mobile/prep-session.js'),'utf8').replace("import {rpc} from './device.js';",'const rpc=()=>{throw Error("Unexpected production call");};').replace("import bundled from './prep-catalog.json';",'const bundled='+JSON.stringify(bundled)+';');
 const {createPrepTransport}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
 let row;const calls=[];
 const oldAPI=async(name,args={})=>{
  calls.push({name,args:structuredClone(args)});
  if(name==='prep_catalog')return {problems:bundled.filter(p=>!/-\d+$/.test(p.id))};
  if(name==='prep_create'){assert(['project','disagreement','setback'].includes(args.problem_id));return row={id:'owner-session',revision:0,data:{problem_id:args.problem_id,answer:'',notes:'',canvas:{nodes:[],edges:[]}},feedback:[]};}
  if(name==='prep_save'){
   assert.equal(args.revision,row.revision);const data=structuredClone(args.data);delete data.behavioral;
   assert(['project','disagreement','setback'].includes(data.problem_id));assert(JSON.stringify(data.canvas).length<=50000);
   row={...row,revision:row.revision+1,data};return structuredClone(row);
  }
  if(name==='prep_get')return structuredClone(row);
  if(name==='prep_sessions')return {sessions:[structuredClone(row)]};
  throw Error(name);
 };
 let call=createPrepTransport(oldAPI);
 const catalog=await call('prep_catalog');assert.equal(catalog.problems.length,15);assert.equal(new Set(catalog.problems.map(p=>p.id)).size,15);
 const made=await call('prep_create',{problem_id:'disagreement-2'});assert.equal(made.data.problem_id,'disagreement-2');
 const workflow={focus:'Teamwork and disagreement',plan:['disagreement-2','disagreement-3','disagreement-4'],index:0,history:[],complete:false,local_id:'local-audio',recording_id:'server-audio'};
 const saved=await call('prep_save',{id:made.id,revision:made.revision,data:{...made.data,answer:'My reviewed answer.',behavioral:workflow}});
 assert.equal(saved.data.answer,'My reviewed answer.');assert.equal(saved.data.problem_id,'disagreement-2');assert.deepEqual(saved.data.behavioral,workflow);
 assert(!row.data.behavioral);assert.match(row.data.notes,/Practice question:/);assert.match(row.data.notes,/changed your mind/);
 // A fresh transport has no in-memory session state; all workflow information is on the owner-scoped API.
 call=createPrepTransport(oldAPI);assert.deepEqual((await call('prep_get',{id:made.id})).data,saved.data);
 assert.equal((await call('prep_sessions')).sessions[0].data.behavioral.local_id,'local-audio');
 const history=[{index:0,answer:saved.data.answer,feedback:{summary:'Verified fixture'},recording_id:'server-audio'}];
 const next=await call('prep_save',{id:made.id,revision:saved.revision,data:{...saved.data,problem_id:'disagreement-3',answer:'',behavioral:{...workflow,index:1,history}}});
 assert.equal(next.data.problem_id,'disagreement-3');assert.deepEqual(next.data.behavioral.history,history);
 await assert.rejects(call('prep_save',{id:made.id,revision:next.revision,data:{...next.data,behavioral:{...workflow,history:[{answer:'x'.repeat(50000)}]}}}),/storage limit/);
 assert.equal(row.revision,next.revision,'Oversized drafts are rejected before mutation');
 console.log('PASS Prep existing API compatibility: distinct prompts, real answer field, persisted workflow/audio IDs/history, fresh-client restoration, revision and storage limits. Controlled old-server contract.');
})().catch(e=>{console.error(e);process.exit(1);});
