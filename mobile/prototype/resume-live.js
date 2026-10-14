// Resume actions on the real account. Each call returns the fresh snapshot through the shared store, so every
// screen (library, Applications, tools) sees the same resumes. Uploads, parsing and LaTeX builds run on the server.
import {call,upload,pdfDataUri,bytesToBase64} from './backend';
import {applyBootstrap,mutate,refreshLive,liveState,reviewOf,setReview} from './live-store';
import {valuesFrom,valuesOfSections,detailsOf,libraryFrom} from './resume-map';
const fileBase64=async file=>bytesToBase64(new Uint8Array(await file.arrayBuffer()));
export const library=()=>{const {boot,reviews}=liveState();return libraryFrom(boot,reviews);};
export const savedJobs=()=>(liveState().boot?.applications||[]).filter(a=>!a.demo);
// Sends a picked PDF (from the document picker) and returns the new resume's id once the server has it.
export async function uploadPdf(file,onProgress=()=>{}){
 const before=new Set((liveState().boot?.resumes||[]).map(r=>r.id));
 const started=Date.now(),result=await upload('upload_resume',{name:file.name,content:await fileBase64(file),transfer_ms:0},onProgress);
 applyBootstrap(result);
 const created=(result.resumes||[]).find(r=>!before.has(r.id))||(result.resumes||[]).find(r=>r.name===file.name);
 return created?.id||'';
}
export async function loadReview(id){
 const review=await call('agent_extract_resume',{id});
 setReview(id,{...review,values:valuesOfSections(review.sections)});
 return reviewOf(id);
}
// Saves the screens' six fields; only the parts whose text changed are rewritten (see resume-map.js).
export async function saveDetails(id,details,confirm){
 const review=reviewOf(id)||await loadReview(id);
 const values=valuesFrom(details,review.values||{});
 const result=await call('resume_save_details',{id,revision:review.revision,values,confirm:!!confirm});
 setReview(id,{...result,values:valuesOfSections(result.sections)});
 await refreshLive({quiet:true});
 return result;
}
export const setDefault=id=>mutate('change_resume',{id,action:'select'});
export const renameResume=(id,name)=>mutate('change_resume',{id,action:'rename',name});
export const deleteResume=id=>mutate('change_resume',{id,action:'delete'});
export const applyTemplate=(id,template)=>mutate('use_resume_template',{id,template});
export const removeFormat=id=>mutate('use_resume_template',{id,template:''});
export async function uploadSource(id,file,onProgress=()=>{}){
 const result=await upload('upload_resume_source',{id,name:file.name,content:await fileBase64(file),transfer_ms:0},onProgress);
 return applyBootstrap(result);
}
export async function originalPdf(id){const r=await call('read_resume',{id});return pdfDataUri(r.content);}
export async function formatPreview(id){const r=await call('read_resume_source',{id});return {uri:pdfDataUri(r.preview.content),tex:r.tex,format:r.format};}
export async function tailoredFile(id){const r=await call('read_tailored_resume',{id});return {uri:pdfDataUri(r.pdf.content),name:r.pdf.name,tex:r.tex};}
export const checkTailored=id=>mutate('check_tailored_resume',{id});
export const removeTailored=id=>mutate('delete_tailored_resume',{id});
// Rule-based match and quality scores for the resume attached to a saved job (no model involved).
export async function scoreFor(applicationId){return call('score_resume',{application_id:applicationId});}
export const detailsFor=id=>{const review=reviewOf(id);return review?detailsOf(review.values):null;};
