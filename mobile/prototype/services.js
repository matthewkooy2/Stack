// Shared mock boundary. Product controllers never import browser or OS storage.
// Configure a platform adapter before mounting screens; no production endpoints.
let adapter={save:()=>{},copy:async()=>{},pick:async()=>null,exportFile:async()=>{},fileUri:file=>file?.uri||'',releaseFile:()=>{}};
const values=new Map(),listeners=new Map();let counter=0;
export const events={
 addEventListener(name,fn){if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name).add(fn);},
 removeEventListener(name,fn){listeners.get(name)?.delete(fn);},
 dispatchEvent(event){listeners.get(event.type)?.forEach(fn=>fn(event));},
 emit(name,detail){this.dispatchEvent({type:name,detail});}
};
// A native adapter may set `deferSave`: writes are then coalesced and flushed shortly after, off the
// interaction path (and whenever the app leaves the foreground), instead of rewriting the whole file
// on every change. Without it (browser preview) each change is saved immediately.
let saveTimer=null;
export function flushStorage(){
 if(saveTimer){clearTimeout(saveTimer);saveTimer=null;}
 try{adapter.save(Object.fromEntries(values));}catch(e){console.warn('Stack could not save local data:',e?.message||e);}
}
function persist(){
 if(!adapter.deferSave){adapter.save(Object.fromEntries(values));return;}
 if(!saveTimer)saveTimer=setTimeout(flushStorage,300);
}
export const storage={
 getItem:key=>values.get(key)??null,
 setItem(key,value){const before=values.get(key);values.set(key,String(value));try{persist();}catch(e){if(before===undefined)values.delete(key);else values.set(key,before);throw e;}},
 removeItem(key){const before=values.get(key);values.delete(key);try{persist();}catch(e){if(before!==undefined)values.set(key,before);throw e;}},
 clear(){values.clear();if(adapter.deferSave)flushStorage();else adapter.save({});},
 snapshot:()=>Object.fromEntries(values)
};
const files=new Map();
export const services={
 online:true,
 id:()=>`mock-${Date.now()}-${++counter}`,
 copy:text=>adapter.copy(text),
 pick:options=>adapter.pick(options),
 exportFile:(data,name,type)=>adapter.exportFile(data,name,type),
 fileUri:file=>adapter.fileUri(file),releaseFile:uri=>adapter.releaseFile(uri),
 async storeFile(id,file){if(adapter.storeFile)await adapter.storeFile(id,file);storage.setItem('file:'+id,JSON.stringify({uri:file.uri,name:file.name,size:file.size}));files.set(id,file);},
 async loadFile(id){return files.get(id)||(adapter.loadFile?await adapter.loadFile(id):JSON.parse(storage.getItem('file:'+id)||'null'));},
 reset(){storage.clear();files.clear();events.emit('reset');events.emit('stack-data-changed');}
};
export function configureServices(next,initial={}){adapter={...adapter,...next};for(const [key,value] of Object.entries(initial))values.set(key,value);}
export const clone=value=>JSON.parse(JSON.stringify(value));
