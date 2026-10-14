// A practice answer on the real account: the spoken answer becomes a transcript (on the phone when it can, else on
// the PC worker), is saved to the practice session, and is coached when coaching is set up.
import {call,upload,describeError} from './backend';
import {saveSession,startCoaching,coachingAvailability,runDetail,reviewFrom} from './prep-live';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
// Sends a saved recording to the PC transcription worker and waits for its text.
export async function pcTranscript(clientId,content,onStage=()=>{}){
 onStage('Uploading your answer…');
 const sent=await upload('transcription_upload',{client_id:clientId,content,local_transcript:''});
 if(!sent?.id)throw new Error('Your answer could not be uploaded for transcription.');
 const stop=Date.now()+240000;
 while(Date.now()<stop){
  const job=await call('transcription_get',{id:sent.id});
  if(job.status==='completed'&&job.transcript)return job.transcript;
  if(['failed','cancelled'].includes(job.status))throw new Error(job.message||'Transcription did not finish. Record the answer again.');
  onStage('Transcribing your answer…');
  await sleep(2500);
 }
 throw new Error('Transcription is taking longer than expected. Your recording stays saved on this phone.');
}
// Saves the answer, then coaches it. Returns {session, review|null, message}: no review means coaching is unavailable.
export async function coachAnswer({questionId,applicationId='',transcript,seconds},onStage=()=>{}){
 onStage('Saving your answer…');
 const session=await saveSession(questionId,{answer:transcript,transcript,elapsed_seconds:Math.max(1,Math.min(86400,Math.round(seconds)))},applicationId);
 const gate=coachingAvailability();
 if(!gate.ready)return {session,review:null,message:gate.message||'Coaching is not set up for your account yet. Your answer is saved.'};
 onStage('Reviewing your answer…');
 let run=await startCoaching(session);
 const stop=Date.now()+180000;
 while(Date.now()<stop){
  run=await runDetail(run.id);
  if(run.status==='completed'){const review=reviewFrom(run);if(review)return {session,review,message:''};break;}
  if(['failed','cancelled','blocked','needs_input','uncertain'].includes(run.status))return {session,review:null,message:run.message||'Coaching could not finish. Your answer is saved; open Agents to see why.'};
  await sleep(2500);
 }
 return {session,review:null,message:'Coaching is taking longer than expected. Your answer is saved; check Agents for the result.'};
}
export const failure=describeError;
