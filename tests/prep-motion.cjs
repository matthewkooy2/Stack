// Motion behavior of the Prep workflow's shared transitions, with React Native's Animated replaced by a recorder.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const root=path.resolve(__dirname,'..'),req=createRequire(path.join(process.env.MAT5_NATIVE_MODULES||path.join(root,'.jac/mobile-rn'),'package.json'));
const React=req('react'),renderer=req('react-test-renderer'),babel=req('@babel/core'),{act}=renderer;
globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const log=[];let reduceMotion=false;
class Value{constructor(v){this.v=v;}setValue(v){this.v=v;log.push({kind:'set',value:v});}interpolate(config){return {from:this,config};}}
const animation=(kind,value,config)=>({start(done){log.push({kind,value,config});done?.({finished:true});},stop(){}});
const primitive=name=>props=>React.createElement(name,props,props.children);
const RN={View:primitive('View'),Pressable:primitive('Pressable'),Platform:{OS:'ios'},
  Easing:{bezier:()=>x=>x,out:f=>f,quad:x=>x,inOut:f=>f,sin:x=>x},
  AccessibilityInfo:{isReduceMotionEnabled:async()=>reduceMotion,addEventListener:()=>({remove(){}})},
  Animated:{Value,View:primitive('AnimatedView'),createAnimatedComponent:C=>C,
    timing:(v,c)=>animation('timing',v,c),spring:(v,c)=>animation('spring',v,c),sequence:items=>({start(){log.push({kind:'sequence'});},stop(){}}),
    loop:inner=>({start(){log.push({kind:'loop'});},stop(){log.push({kind:'loop-stop'});}})}};
function loadMotion(){
  const filename=path.join(root,'mobile/prep-motion.js');
  const code=babel.transformSync(fs.readFileSync(filename,'utf8'),{filename,babelrc:false,configFile:false,plugins:[req('@babel/plugin-transform-modules-commonjs')]}).code;
  const module={exports:{}};
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename})(name=>name==='react-native'?RN:req(name),module,module.exports);
  return module.exports;
}
const flush=()=>new Promise(resolve=>setTimeout(resolve,5));
const h=React.createElement;
const kinds=kind=>log.filter(e=>e.kind===kind);
const find=(ui,type)=>ui.root.findAll(n=>n.type===type);
async function render(element){let ui;await act(async()=>{ui=renderer.create(element);await flush();});return ui;}
async function update(ui,element){await act(async()=>{ui.update(element);await flush();});}

async function run(){
  let m=loadMotion();await flush();
  // Stage: forward onto a deeper step, backward onto a shallower one, forward when the question number advances.
  const stageDir=ui=>find(ui,'AnimatedView')[0].props.style.at(-1).transform[0].translateX.config.outputRange[0];
  let ui=await render(h(m.PrepStage,{pageKey:'home',step:0},h('Text',null,'home')));
  await update(ui,h(m.PrepStage,{pageKey:'type',step:0},h('Text',null,'type')));assert.equal(stageDir(ui),22,'deeper step slides in from the right');
  await update(ui,h(m.PrepStage,{pageKey:'coaching',step:0},h('Text',null,'coaching')));
  await update(ui,h(m.PrepStage,{pageKey:'question',step:0},h('Text',null,'again')));assert.equal(stageDir(ui),-22,'retrying the same answer slides back');
  await update(ui,h(m.PrepStage,{pageKey:'coaching',step:0},h('Text',null,'coaching')));
  await update(ui,h(m.PrepStage,{pageKey:'question',step:1},h('Text',null,'next')));assert.equal(stageDir(ui),22,'the next question moves forward');
  await update(ui,h(m.PrepStage,{pageKey:'home',step:1},h('Text',null,'home')));assert.equal(stageDir(ui),-22,'returning home slides back');
  const stages=kinds('timing').filter(e=>e.config.duration===m.MOTION.stage);assert(stages.length>=6,'every step change runs the stage animation');
  assert.equal(JSON.stringify(ui.toJSON()).includes('"home"'),true);
  await act(async()=>ui.unmount());

  // Reveal staggers siblings and caps the delay.
  log.length=0;
  ui=await render(h('View',null,[0,1,2,20].map(i=>h(m.Reveal,{key:i,index:i},h('Text',null,String(i))))));
  const delays=kinds('timing').map(e=>e.config.delay);
  assert.deepEqual(delays,[40,95,150,40+8*m.MOTION.stagger],'siblings stagger and the delay is capped');
  assert(kinds('timing').every(e=>e.config.useNativeDriver===true&&e.config.toValue===1));
  await act(async()=>ui.unmount());

  // Tap: press in shrinks, release springs back, enabling and disabling fade rather than snap.
  log.length=0;let pressed=0;
  ui=await render(h(m.Tap,{accessibilityLabel:'Go',onPress:()=>pressed++,disabled:false},h('Text',null,'Go')));
  const pressable=()=>find(ui,'Pressable')[0];
  await act(async()=>pressable().props.onPressIn());assert.equal(kinds('timing').at(-1).config.toValue,0.97);
  await act(async()=>pressable().props.onPressOut());assert.equal(kinds('spring').at(-1).config.toValue,1);
  await act(async()=>pressable().props.onPress());assert.equal(pressed,1,'press still reaches the handler');
  log.length=0;await update(ui,h(m.Tap,{accessibilityLabel:'Go',onPress:()=>pressed++,disabled:true},h('Text',null,'Go')));
  assert.equal(kinds('timing').at(-1).config.toValue,0.45,'disabling fades to the dim level');assert.equal(pressable().props.disabled,true);
  await update(ui,h(m.Tap,{accessibilityLabel:'Go',onPress:()=>pressed++,disabled:true,dim:1},h('Text',null,'Go')));
  await act(async()=>ui.unmount());

  // FadeSwitch: fades out and unmounts, keeps its last content while fading, and can hold layout space.
  log.length=0;
  ui=await render(h(m.FadeSwitch,{show:false},h('Text',null,'hidden')));assert.equal(ui.toJSON(),null,'hidden content is not rendered');
  await update(ui,h(m.FadeSwitch,{show:true},h('Text',null,'Saving')));assert(JSON.stringify(ui.toJSON()).includes('Saving'));
  await update(ui,h(m.FadeSwitch,{show:false},h('Text',null,'')));
  assert.equal(kinds('timing').at(-1).config.toValue,0);assert.equal(ui.toJSON(),null,'unmounts after fading out');
  await update(ui,h(m.FadeSwitch,{show:true,keep:true},h('Text',null,'again')));await update(ui,h(m.FadeSwitch,{show:false,keep:true},h('Text',null,'again')));
  assert(ui.toJSON()!==null,'keep holds its space after hiding');
  await act(async()=>ui.unmount());

  // Halo only loops while active, and stops looping when it stops.
  log.length=0;
  ui=await render(h(m.Halo,{active:false},h('Text',null,'icon')));assert.equal(kinds('loop').length,0);
  await update(ui,h(m.Halo,{active:true},h('Text',null,'icon')));assert.equal(kinds('loop').length,1,'active halo pulses');
  await update(ui,h(m.Halo,{active:false},h('Text',null,'icon')));assert.equal(kinds('loop-stop').length,1,'pulse stops with the activity');
  await act(async()=>ui.unmount());

  // Reduce motion: nothing animates, content is immediately visible and loops never start.
  reduceMotion=true;m=loadMotion();await flush();log.length=0;
  ui=await render(h('View',null,h(m.PrepStage,{pageKey:'home'},h(m.Reveal,{index:3},h('Text',null,'shown')),h(m.Halo,{active:true},h('Text',null,'icon')),h(m.Breathe,null,h('Text',null,'breathe')),h(m.Pop,null,h('Text',null,'pop')))));
  await update(ui,h('View',null,h(m.PrepStage,{pageKey:'type'},h(m.Reveal,{index:3},h('Text',null,'shown')),h(m.Halo,{active:true},h('Text',null,'icon')),h(m.Breathe,null,h('Text',null,'breathe')),h(m.Pop,null,h('Text',null,'pop')))));
  assert.equal(kinds('timing').length+kinds('spring').length+kinds('loop').length,0,'reduce motion must not start animations: '+JSON.stringify(kinds('loop')));
  assert(JSON.stringify(ui.toJSON()).includes('shown'));
  await act(async()=>ui.unmount());
  console.log('PASS Prep motion: directional step transitions, capped sibling stagger, press feedback and disabled fade, fade lifecycle, activity-bound pulses, and reduce-motion.');
}
run().catch(e=>{console.error(e);process.exitCode=1;});
