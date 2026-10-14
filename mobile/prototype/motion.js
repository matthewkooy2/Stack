import React,{useEffect,useRef,useState,useId} from 'react';
import {View,Animated,AccessibilityInfo} from 'react-native';
import Svg,{Defs,LinearGradient,Stop,Rect} from 'react-native-svg';
// One shared reduce-motion subscription instead of one per component.
let reduceMotion=false;const reduceListeners=new Set();
const setReduceMotion=value=>{reduceMotion=!!value;reduceListeners.forEach(fn=>fn(reduceMotion));};
AccessibilityInfo.isReduceMotionEnabled().then(setReduceMotion);AccessibilityInfo.addEventListener('reduceMotionChanged',setReduceMotion);
export function usePulse(active){
 const ref=useRef(null);if(ref.current===null)ref.current=new Animated.Value(1);const value=ref.current;
 useEffect(()=>{
  if(!active)return;
  let animation;
  const update=reduce=>{
   animation?.stop();value.setValue(1);
   if(reduce)return;
   animation=Animated.loop(Animated.sequence([Animated.timing(value,{toValue:.5,duration:1000,useNativeDriver:true}),Animated.timing(value,{toValue:1,duration:1000,useNativeDriver:true})]));
   animation.start();
  };
  update(reduceMotion);reduceListeners.add(update);
  return()=>{reduceListeners.delete(update);animation?.stop();value.setValue(1);};
 },[active]);
 return value;
}
export function Gradient({orb=false}){const id=useId().replace(/:/g,'');return <Svg pointerEvents="none" style={{position:'absolute',top:0,left:0,width:'100%',height:'100%'}}><Defs><LinearGradient id={id} x1="0%" y1="0%" x2="100%" y2="100%"><Stop offset="0" stopColor={orb?'#d6deef':'#f1f3fa'}/><Stop offset="1" stopColor={orb?'#bccae3':'#e9edf5'}/></LinearGradient></Defs><Rect width="100%" height="100%" fill={`url(#${id})`}/></Svg>;}
function Bar({index,active}){const value=usePulse(active);return <Animated.View style={{width:3,height:active?[4,8,12,15,12,8,4][index]:4,borderRadius:3,backgroundColor:'#9fafd0',transform:[{scaleY:active?value:1}]}}/>;}
export function Wave({active}){return <View accessibilityElementsHidden style={{height:15,flexDirection:'row',alignItems:'center',gap:3}}>{Array.from({length:7},(_,i)=><Bar key={i} index={i} active={active}/>)}</View>;}
