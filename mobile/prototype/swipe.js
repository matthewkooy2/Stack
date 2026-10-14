// Native swipe card: the gesture and the card transform run on the UI thread (Gesture Handler +
// Reanimated), so dragging stays smooth even while the JS thread is busy rendering.
import React,{useCallback,useEffect,useMemo,useRef} from 'react';
import {AccessibilityInfo} from 'react-native';
import {Gesture,GestureDetector} from 'react-native-gesture-handler';
import Animated,{Extrapolation,cancelAnimation,interpolate,useAnimatedStyle,useSharedValue,withTiming} from 'react-native-reanimated';
import {scheduleOnRN} from 'react-native-worklets';
import {SWIPE_THRESHOLD,TILT_RANGE,LEAVE_DISTANCE,LEAVE_MS,RETURN_MS,ACTIVATE_DX,intentOf,leavingOf,heldDragOf} from './swipe-intent';
export function SwipeCard({children,spec,disabled,style,a11y}){
 const x=useSharedValue(0),intent=useSharedValue(0),exiting=useSharedValue(0),reduced=useSharedValue(false),active=useSharedValue(false);
 const latest=useRef(spec);latest.current=spec;
 const report=useCallback(value=>latest.current.onDrag?.(value,false),[]);
 const leaving=leavingOf(spec),heldDrag=heldDragOf(spec),leavingNow=useRef('');leavingNow.current=leaving;
 const commit=useCallback(direction=>{
  latest.current.onSwipe?.(direction);
  // Failsafe: if the screen ignored the swipe (nothing started leaving), bring the card back.
  setTimeout(()=>{if(!leavingNow.current&&!active.value&&exiting.value!==0){exiting.value=0;x.value=withTiming(0,{duration:RETURN_MS});}},600);
 },[]);
 useEffect(()=>{AccessibilityInfo.isReduceMotionEnabled().then(value=>{reduced.value=value;});const sub=AccessibilityInfo.addEventListener('reduceMotionChanged',value=>{reduced.value=value;});return()=>sub.remove();},[]);
 useEffect(()=>{
  if(leaving){
   // The release handler already started this exit on the UI thread; do not restart it.
   if(exiting.value!==(leaving==='save'?1:-1))x.value=withTiming(leaving==='save'?LEAVE_DISTANCE:-LEAVE_DISTANCE,{duration:reduced.value?0:LEAVE_MS});
  }else if(!active.value){cancelAnimation(x);exiting.value=0;intent.value=0;x.value=heldDrag;}
 },[leaving,heldDrag]);
 const pan=useMemo(()=>Gesture.Pan().enabled(!disabled).activeOffsetX([-ACTIVATE_DX,ACTIVATE_DX]).failOffsetY([-12,12])
  .onUpdate(event=>{
   'worklet';
   if(exiting.value!==0)return;
   if(!active.value){active.value=true;cancelAnimation(x);} // grabbing a card that is still settling
   x.value=event.translationX;
   const next=intentOf(event.translationX);
   if(next!==intent.value){intent.value=next;scheduleOnRN(report,next);}
  })
  .onEnd((event,success)=>{
   'worklet';
   active.value=false;
   if(exiting.value!==0)return;
   if(success&&Math.abs(event.translationX)>=SWIPE_THRESHOLD){
    const direction=event.translationX>0?1:-1;
    exiting.value=direction;x.value=withTiming(direction*LEAVE_DISTANCE,{duration:reduced.value?0:LEAVE_MS});
    scheduleOnRN(commit,direction>0?'save':'pass');
   }else{
    x.value=withTiming(0,{duration:reduced.value?0:RETURN_MS});
    if(intent.value!==0){intent.value=0;scheduleOnRN(report,0);}
   }
  }),[disabled]);
 const motion=useAnimatedStyle(()=>({transform:[{translateX:x.value},{rotate:interpolate(x.value,[-TILT_RANGE,0,TILT_RANGE],[-9,0,9],Extrapolation.CLAMP)+'deg'}]}));
 return <GestureDetector gesture={pan}><Animated.View {...a11y} style={[style,motion]}>{children}</Animated.View></GestureDetector>;
}
