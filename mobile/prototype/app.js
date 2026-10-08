import React,{useCallback,useEffect,useRef,useState,useSyncExternalStore} from 'react';
import {Text,View,Animated,Modal} from 'react-native';
import {usePulse} from './motion';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {NativeFrame,setBackFallback,TabOwner,setActiveOwner} from './controls';
import {ReviewMenu} from './review-controls';
import {preparePlatform} from './platform';
import {installTemplates} from './render';
import {setReviewScreen,useReviewState} from './loading';
import {events} from './services';
import {backend,onBackendChange} from './backend';
import {JobsPreview} from './jobs-controller';
import {ApplicationsPreview} from './applications-controller';
import {NetworkPreview} from './network-controller';
import {ResumePreview} from './resume-controller';
import {PrepPreview} from './applications-prep-controller';
import {subscribeScenarios,scenarioRevision} from './scenarios';
let navigate=()=>{};
export function ReviewBridge({screen,onNavigate}){navigate=onNavigate;useEffect(()=>{setReviewScreen(screen);setBackFallback(()=>{if(['signup','signin'].includes(screen)){onNavigate('welcome');return true;}return false;});return()=>setBackFallback(()=>false);},[screen]);return null;}
// Live builds say so when Stack cannot be reached; screens keep what they already show and recover on their own.
function OfflineBanner(){
 const online=useSyncExternalStore(onBackendChange,()=>backend.online);
 return online?null:<View accessibilityRole="alert" accessibilityLiveRegion="polite" style={{paddingVertical:6,paddingHorizontal:14,backgroundColor:'#FFF4E5'}}><Text style={{fontSize:12,color:'#8A4B08'}}>Cannot reach Stack. Showing what is saved; we will keep trying.</Text></View>;
}
export function RootFrame({children}){
 const [ready,setReady]=useState(false),[error,setError]=useState('');
 const {screen}=useReviewState();

 useEffect(()=>{preparePlatform().then(()=>{events.emit('hydrate');setReady(true);}).catch(e=>setError(e.message));},[]);
 return <SafeAreaProvider><NativeFrame backgroundColor={screen==='Prep'?'#FFFDE7':undefined}><View style={{flex:1,minHeight:0,overflow:'hidden'}}>{backend.live?<OfflineBanner/>:null}{ready?children:<View><Text>{error||'Opening your Stack…'}</Text></View>}</View><ReviewMenu onNavigate={screen=>navigate(screen)}/></NativeFrame></SafeAreaProvider>;
}
function LegacyLoading({screen}){const pulse=usePulse(true),title=screen==='Edit profile'?'Preferences':screen;return <View style={{flex:1,padding:24,gap:24,backgroundColor:'#f6f7fb'}}><View style={{flexDirection:'row',alignItems:'center',justifyContent:'space-between'}}><Text style={{fontSize:23,fontWeight:'800',letterSpacing:-.5,color:'#202b40'}}>{title}</Text><Animated.View accessibilityElementsHidden style={{width:14,height:14,borderWidth:2,borderColor:'#dce4f4',borderTopColor:'#3765e8',borderRadius:7,opacity:pulse}}/></View><Text accessibilityRole="text" accessibilityLiveRegion="polite" style={{fontSize:13,color:'#748096'}}>Loading your {title.toLowerCase()}…</Text><View accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{padding:22,gap:17,backgroundColor:'white',borderWidth:1,borderColor:'#e9edf4',borderRadius:24}}>{[{width:50,height:50,borderRadius:15},{width:'85%',height:23,marginVertical:8},{height:12},{height:12,width:'73%'},{height:44,marginVertical:8}].map((style,i)=><Animated.View key={i} style={{borderRadius:6,backgroundColor:'#e9edf4',opacity:pulse,...style}}/>)}</View></View>;}
const TABS={Jobs:JobsPreview,Applications:ApplicationsPreview,Network:NetworkPreview,Resume:ResumePreview,Prep:PrepPreview};
const shown={flex:1,minHeight:0},hidden={display:'none'};
// Props are stable, so a tab re-renders only for its own state, never because the app shell did.
const Tab=React.memo(function Tab({name,onNavigate,onProfile}){const Component=TABS[name];return <Component onNavigate={onNavigate} onProfile={onProfile}/>;});
// Visited tabs stay mounted (hidden) so switching back is instant and keeps its place. A hidden tab is
// remounted on its next visit if stored data changed meanwhile, which is also how cross-tab handoffs
// (e.g. Applications to Resume or Prep) reach their destination: it reads them when it mounts.
export function CombinedScreen({screen,onNavigate,onProfile,templates}){
 installTemplates(templates);const revision=useSyncExternalStore(subscribeScenarios,scenarioRevision);
 const latest=useRef({}),navigate=useCallback(next=>latest.current.onNavigate(next),[]),profile=useCallback(()=>latest.current.onProfile(),[]);latest.current={onNavigate,onProfile};
 const tabs=useRef({revision,visits:new Map(),dirty:new Set(),current:screen}).current;
 if(tabs.revision!==revision){tabs.revision=revision;tabs.visits.clear();tabs.dirty.clear();}
 useEffect(()=>{const changed=()=>{for(const name of tabs.visits.keys())if(name!==tabs.current)tabs.dirty.add(name);};events.addEventListener('stack-data-changed',changed);return()=>events.removeEventListener('stack-data-changed',changed);},[]);
 if(tabs.dirty.delete(screen)||!tabs.visits.has(screen))tabs.visits.set(screen,(tabs.visits.get(screen)||0)+1);
 tabs.current=screen;setActiveOwner(screen);
 return <View style={shown}>{[...tabs.visits].map(([name,visit])=><View key={name+':'+revision+':'+visit} style={name===screen?shown:hidden} pointerEvents={name===screen?'auto':'none'} accessibilityElementsHidden={name!==screen} importantForAccessibility={name===screen?'auto':'no-hide-descendants'}><TabOwner value={name}><Tab name={name} onNavigate={navigate} onProfile={profile}/></TabOwner></View>)}</View>;
}
export function ReviewLegacyContent({children}){return children;}
// Loading belongs inside the native modal: portals are outside the root layout.
export function ReviewModal({children,...props}){const {mode,screen}=useReviewState();return <Modal {...props}>{mode==='loading'&&['Profile','Edit profile','Agents'].includes(screen)?<LegacyLoading screen={screen}/>:children}</Modal>;}