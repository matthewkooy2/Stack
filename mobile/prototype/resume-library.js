import {storage,events,services,clone} from './services';
import {backend} from './backend';
import {liveState} from './live-store';
import {libraryFrom} from './resume-map';
// Shared local prototype contract for Resume and Applications.
export const LIBRARY_KEY='stack.resume.library.v1';
const emptyDetails={name:'',email:'',location:'',experience:'',education:'',skills:''};
export function formatOf(r){
 if(r.format===null)return null;
 return r.format||((r.kind==='template'||r.hasLatex)?{kind:'builtin',template:r.template||'jake',status:'completed'}:null);
}
export function normalizeResume(r){
 const tailored=!!r.tailored||r.kind==='tailored';
 const format=formatOf(r);
 return {...r,id:String(r.id),details:{...emptyDetails,...r.details},tailored,
  isDefault:!tailored&&!!r.isDefault,format,hasLatex:format?.status==='completed',
  ...(tailored?{sourceId:String(r.sourceId??r.source_resume_id??''),sourceName:r.sourceName||'Original resume',
   job:r.job||{id:String(r.application_id||''),role:'Saved application',company:''},createdAt:r.createdAt||0}:{} )};
}
export function readLibrary(){
 // Live builds read the account's resumes; the library is never stored on the device.
 if(backend.live){const {boot,reviews}=liveState();return libraryFrom(boot,reviews).map(normalizeResume);}
 try{const value=JSON.parse(storage.getItem(LIBRARY_KEY));return Array.isArray(value)?value.map(normalizeResume):[];}catch{return [];}
}
export function saveLibrary(value){
 if(backend.live)throw Error('The Resume library lives in your Stack account; use its actions instead.');
 const normalized=value.map(normalizeResume);
 storage.setItem(LIBRARY_KEY,JSON.stringify(normalized));
 events.emit('stack-data-changed');
 return normalized;
}
export function resumeFingerprint(resume){
 return JSON.stringify(resume?{id:String(resume.id),details:resume.details,blobId:resume.blobId,format:formatOf(resume)}:null);
}
