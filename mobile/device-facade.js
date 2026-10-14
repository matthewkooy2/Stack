export * from './mock-device.js';
import * as mock from './mock-device.js';
import {authSession,realAuthEnabled,liveData} from './auth-platform';
import {services} from './prototype/services';
import {configureBackend} from './prototype/backend';
import {applyBootstrap} from './prototype/live-store';
import * as live from './live-device.js';
export {realAuthEnabled,liveData};
// Live data: every account call goes through the signed-in session; the product screens share this transport.
if(liveData)mock.borrowSession({token:()=>authSession.token(),origin:authSession.origin});
if(liveData)configureBackend({live:true,call:(name,args,options)=>authSession.call(name,args,options),upload:(name,args,onProgress)=>authSession.upload(name,args,onProgress)});
const authCalls=new Set(['auth_google_status','auth_google_recover','agent_admission','agent_accept_invite']);
export const restoreSession=()=>realAuthEnabled?authSession.restoreSession():mock.restoreSession();
export const authenticate=(...args)=>realAuthEnabled?authSession.authenticate(...args):mock.authenticate(...args);
export const authenticateProvider=(...args)=>realAuthEnabled?authSession.authenticateProvider(...args):mock.authenticateProvider(...args);
export const cancelGoogleSignIn=()=>realAuthEnabled?authSession.cancel():Promise.resolve();
export async function recoverGoogleAccount(username,password){if(!realAuthEnabled)throw Error('Account recovery requires the Google test build.');await authSession.recover(username,password);services.reset();}
export async function signOut(){if(realAuthEnabled){await authSession.signOut();services.reset();if(liveData)await live.clearLocalAccountData();}await mock.signOut();}
export async function rpc(name,args={}){
 if(authCalls.has(name)){if(realAuthEnabled)return authSession.rpc(name,args);return name==='auth_google_status'?{}:name==='agent_admission'?{admitted:true}:{};}
 if(liveData){const result=await authSession.call(name,args);applyBootstrap(result);return result;}
 return mock.rpc(name,args);
}
export const pickResume=liveData?live.pickResume:mock.pickResume;
export const previewResume=liveData?live.previewResume:mock.previewResume;
export const uploadResumeFile=liveData?live.uploadResumeFile:mock.uploadResumeFile;
export const reconcileNotifications=liveData?live.reconcileNotifications:mock.reconcileNotifications;
export const Lifecycle=liveData?live.Lifecycle:mock.Lifecycle;
export const persistSwipe=liveData?(id,action)=>rpc('swipe',{job_id:id,action,start_agent:false}):mock.persistSwipe;
