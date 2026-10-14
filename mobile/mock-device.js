// Explicit mock implementation for the combined UI. Never calls production RPCs.
export * from './native-device.js';
import {storage,services,clone} from './prototype/services';
import {getReviewMode} from './prototype/loading';
const preferences={stage:'Student',years:null,education:'',modes:[],employment_types:[],salary_min:0,salary_period:'year',exclude_companies:[],exclude_terms:[],soft:[]};
let state={user_id:'prototype-student',profile:{name:'Alex',role:'',location:'United States',mode:'Any',notifications:false,onboarded:false,graduation_month:'',available_from:'',preferences},applications:[],contacts:[],people:[],resumes:[],reminders:[],decisions:[],selected_resume:'',saved_search:{},tailored_resumes:[],agents:{active:0,attention:0,runs:[],features:[]}};
const features=[['email','Email tracking',['email'],'applications'],['calendar','Calendar review',['calendar'],'prep'],['tailoring','Resume tailoring',['resume'],'resume'],['profile','Profile suggestions',['profile'],'contacts']].map(([key,title,kinds,where])=>({key,title,kinds,where,state:'setup',summary:'Simulated in this UI prototype.',input:'Confirmed sample details',review:'Explicit approval before each simulated action',checks:[],alternative:'Review the corresponding mock workflow from the screen menu.'}));
state.agents.features=features;
const emptySettings={policy:{enabled:false,actions:[],domains:[],followup_limit:0,daily_limits:{}},facts:[],connections:[],web_url:'',account_id:'prototype-student'};
const readSettings=()=>JSON.parse(storage.getItem('mock-agent-settings')||JSON.stringify(emptySettings));
const pause=()=>new Promise(resolve=>setTimeout(resolve,500));
export async function restoreSession(){return storage.getItem('mock-session')==='signed-in';}
export async function authenticate(){await pause();if(getReviewMode()==='error')throw Error('Sign-in failed in this scenario. Choose Normal and retry.');storage.setItem('mock-session','signed-in');return true;}
export const authenticateProvider=authenticate;
export async function signOut(){storage.removeItem('mock-session');}
export async function rpc(name,args={}){
 if(getReviewMode()==='error')throw Error('This mock request failed. Choose Normal and retry.');
 if(name==='agent_settings')return readSettings();
 if(name==='agent_save_policy'){const settings=readSettings();settings.policy=clone(args.policy);storage.setItem('mock-agent-settings',JSON.stringify(settings));return settings;}
 if(name==='agent_save_facts'){const settings=readSettings();for(const fact of args.facts)settings.facts=[...settings.facts.filter(f=>f.key!==fact.key),fact];storage.setItem('mock-agent-settings',JSON.stringify(settings));return settings;}
 if(name==='agent_google_start')throw Error('Google connections are simulated here. Review email and calendar scenarios in the prototype.');
 if(name==='agent_events')return {events:[],interviews:[]};
 if(name==='transcription_list')return {recordings:[],runtime:{}};
 if(name==='prep_catalog')return {problems:[]};
 if(name==='prep_sessions')return {sessions:[]};
 if(name==='save_profile'){state={...state,profile:{...state.profile,...args}};storage.setItem('mock-profile',JSON.stringify(state.profile));}
 if(name==='bootstrap'){const saved=storage.getItem('mock-profile');if(saved)state={...state,profile:JSON.parse(saved)};}
 if(name==='agent_linkedin_profile')return {url:args.url||'',target_role:args.target_role||''};
 return clone(state);
}
export async function reconcileNotifications(){return '';}
export function Lifecycle(){return null;}
export const persistSwipe=async()=>clone(state);
export const uploadResumeFile=async()=>clone(state);
export const pickResume=()=>services.pick({accept:'.pdf'});
