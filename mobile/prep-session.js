// Prep-only compatibility with the existing account API. Workflow metadata travels in
// the API's persisted canvas document; reviewed text stays in its normal answer field.
import {rpc} from './device.js';
import bundled from './prep-catalog.json';
const marker='stack_prep_workflow_v1';
export function decodePrepSession(row){
 if(!row?.data)return row;
 const stored=row.data.canvas?.[marker];
 if(!stored||stored.version!==1||!stored.behavioral)return row;
 const canvas={...row.data.canvas};delete canvas[marker];
 return {...row,data:{...row.data,canvas,problem_id:stored.problem_id,notes:stored.notes||'',behavioral:stored.behavioral}};
}
export function encodePrepData(data,available){
 if(!data?.behavioral)return data;
 const problem=bundled.find(p=>p.id===data.problem_id);
 const actual=available.has(data.problem_id)?data.problem_id:data.problem_id.replace(/-\d+$/,'');
 if(!available.has(actual))throw Error('This behavioral question is unavailable on your account.');
 const canvas={...data.canvas,[marker]:{version:1,problem_id:data.problem_id,notes:data.notes||'',behavioral:data.behavioral}};
 if(JSON.stringify(canvas).length>50000)throw Error('This session exceeds the account storage limit. Your current answer is kept; shorten it before saving.');
 return {...data,problem_id:actual,canvas,notes:actual===data.problem_id?data.notes||'':('Practice question: '+problem.prompt+'\n'+(data.notes||''))};
}
export function createPrepTransport(call){
 let catalogPromise;
 const catalog=()=>catalogPromise||(catalogPromise=call('prep_catalog',{}).then(r=>r.problems).catch(e=>{catalogPromise=null;throw e;}));
 return async(name,args={})=>{
  if(name==='prep_catalog'){
   const existing=await catalog();
   return {problems:[...existing,...bundled.filter(p=>!existing.some(q=>q.id===p.id))]};
  }
  if(name==='prep_create'){
   const available=new Set((await catalog()).map(p=>p.id));
   const actual=available.has(args.problem_id)?args.problem_id:args.problem_id.replace(/-\d+$/,'');
   if(!available.has(actual))throw Error('This behavioral question is unavailable on your account.');
   const made=await call(name,{...args,problem_id:actual});
   return {...made,data:{...made.data,problem_id:args.problem_id}};
  }
  if(name==='prep_save'){
   const available=new Set((await catalog()).map(p=>p.id));
   return decodePrepSession(await call(name,{...args,data:encodePrepData(args.data,available)}));
  }
  if(name==='prep_get')return decodePrepSession(await call(name,args));
  if(name==='prep_sessions'){
   const result=await call(name,args);return {...result,sessions:result.sessions.map(decodePrepSession)};
  }
  return call(name,args);
 };
}
export const prepRpc=createPrepTransport(rpc);
