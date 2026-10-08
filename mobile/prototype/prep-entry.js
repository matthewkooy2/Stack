// General Prep alone changes; job-specific interview plans and all other tabs keep their controllers.
import React,{useEffect,useRef,useState} from 'react';
import {View,Text,Pressable,ScrollView} from 'react-native';
import {Users,BriefcaseBusiness,Layers,FileText,GraduationCap} from 'lucide-react-native';
import {Prep} from '../components/Prep';
import {Reveal} from '../prep-motion';
import {useLive} from './live-store';
import {PrepPreview as ExistingPrep} from './prep-controller';
const tabs=[['Network',Users],['Applications',BriefcaseBusiness],['Jobs',Layers],['Resume',FileText],['Prep',GraduationCap]];
export function PrepPreview({onNavigate,onProfile}){
 const {boot}=useLive();const [stage,setStage]=useState('home'),[height,setHeight]=useState(0),scroller=useRef(null);
 // Each step starts at the top instead of inheriting the previous step's scroll position.
 useEffect(()=>{scroller.current?.scrollTo?.({y:0,animated:false});},[stage]);
 const owner=boot?.user_id||'',agents=boot?.agents||{};
 return <View style={{flex:1,backgroundColor:'#FFFDE7'}}>
  {stage==='home'?<Reveal rise={0}><View style={{paddingHorizontal:24,paddingTop:13,paddingBottom:12,flexDirection:'row',alignItems:'center',justifyContent:'space-between'}}>
   <Text style={{fontSize:29,fontWeight:'800',letterSpacing:-1.2,color:'#2C1D10'}}>stack</Text>
   <View style={{flexDirection:'row',alignItems:'center',gap:16}}>
    <Pressable accessibilityRole="button" accessibilityLabel="Open agents" onPress={()=>onNavigate('Agents')} style={{padding:8}}><Text style={{fontSize:16,color:'#927E69'}}>Agents</Text></Pressable>
    <Pressable accessibilityLabel="Open profile" onPress={onProfile} style={{width:38,height:38,borderRadius:13,backgroundColor:'#FFF1D8',alignItems:'center',justifyContent:'center'}}><Text style={{fontSize:14,fontWeight:'700',color:'#927E69'}}>{boot?.profile?.name?.slice(0,1)||'U'}</Text></Pressable>
   </View>
  </View></Reveal>:null}
  <ScrollView ref={scroller} style={{flex:1}} onLayout={e=>setHeight(e.nativeEvent.layout.height)} contentContainerStyle={{flexGrow:1,paddingHorizontal:24,paddingTop:12,paddingBottom:30}} keyboardShouldPersistTaps="handled">
   {owner?<Prep key={owner} owner={owner} runs={agents.runs||[]} features={agents.features||[]} onStage={setStage} availableHeight={height} onNavigate={onNavigate} onOpenTask={id=>onNavigate('task:'+id)} legacyContent={<ExistingPrep onNavigate={onNavigate} onProfile={onProfile}/>}/>:<Text style={{color:'#927E69',padding:24}}>Loading your Prep sessions…</Text>}
  </ScrollView>
  {stage==='home'?<Reveal rise={0} delay={120}><View style={{flexDirection:'row',justifyContent:'space-around',paddingVertical:16,borderTopWidth:1,borderTopColor:'#ECD8B3'}}>{tabs.map(([name,Icon])=><Pressable key={name} accessibilityRole="tab" accessibilityLabel={name} accessibilityState={{selected:name==='Prep'}} onPress={()=>onNavigate(name)} style={{alignItems:'center',gap:5}}><Icon size={22} color={name==='Prep'?'#44321B':'#B4A087'} strokeWidth={1.8}/><Text style={{fontSize:11,color:name==='Prep'?'#44321B':'#B4A087'}}>{name}</Text></Pressable>)}</View></Reveal>:null}
 </View>;
}
