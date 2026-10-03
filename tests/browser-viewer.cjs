// Shared native viewer under real React, with synthetic OS/network boundaries.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const nativeRequire=createRequire(path.resolve('.jac/mobile-rn/package.json'));
const React=nativeRequire('react'),renderer=nativeRequire('react-test-renderer'),babel=nativeRequire('@babel/core');
const {act}=renderer;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const primitives=new Map();const primitive=name=>{if(!primitives.has(name))primitives.set(name,props=>name==='Modal'&&!props.visible?null:React.createElement(name,props,props.children));return primitives.get(name);};
let listener;const RN=new Proxy({AppState:{addEventListener:(name,fn)=>{listener=fn;return{remove(){}};}},PanResponder:{create:handlers=>({panHandlers:handlers})}},{get:(target,key)=>target[key]||primitive(key)});
const code=babel.transformSync(fs.readFileSync('native/browser-viewer.js','utf8'),{babelrc:false,configFile:false,plugins:[nativeRequire.resolve('@babel/plugin-transform-modules-commonjs')]}).code;
const moduleFixture={exports:{}};vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(name=>name==='react'?React:RN,moduleFixture,moduleFixture.exports);
const {BrowserViewer,createBrowserStream}=moduleFixture.exports;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

async function streamTests(){
 const requests=[],states=[],events=[];
 globalThis.XMLHttpRequest=class{constructor(){requests.push(this);this.headers={};this.responseText='';this.status=0;}open(method,url){this.method=method;this.url=url;}setRequestHeader(k,v){this.headers[k]=v;}send(body){this.body=JSON.parse(body);}abort(){this.aborted=true;this.onabort?.();}};
 const close=createBrowserStream({id:'synthetic-run',origin:'https://stack.example.test/',authorization:'Bearer synthetic',isCurrent:()=>true,onEvent:e=>events.push(e),onState:s=>states.push(s)});
 const r=requests[0];assert.equal(r.url,'https://stack.example.test/browser/stream');assert.equal(r.headers.Authorization,'Bearer synthetic');assert.deepEqual(r.body,{id:'synthetic-run'});
 const packet='data: '+JSON.stringify({control:{mode:'agent'},frame:{image:'synthetic'}})+'\n\n';
 r.status=200;r.responseText=packet.slice(0,13);r.onprogress();assert.equal(events.length,0);
 r.responseText=packet;r.onprogress();assert.equal(events.length,1);
 r.onprogress();assert.equal(events.length,1,'duplicate progress does not duplicate frames');
 r.onload();close();await wait(180);assert.equal(requests.length,1,'closing prevents scheduled reconnect');assert.ok(r.aborted);
 const invalid=[];const stop=createBrowserStream({id:'other',origin:'https://stack.example.test',authorization:'Bearer synthetic',isCurrent:()=>true,onEvent:()=>invalid.push(true),onState:s=>states.push(s)});
 requests[1].status=403;requests[1].onload();stop();assert.equal(invalid.length,0);assert.ok(states.includes('unavailable'));
}

async function viewerTests(){
 const requests=[];let receive,state,closed=0,opened=0,failInput=false;
 const initialFrame={image:'synthetic',width:100,height:200,capture_id:'fixture-context',sequence:1,url:'https://application.example.test/form'};
 const now=()=>Date.now()/1000;
 const openStream=(id,onEvent,onState)=>{assert.equal(id,'application-run');opened++;receive=onEvent;state=onState;return()=>closed++;};
 const requestBrowser=async(name,args)=>{
  requests.push({name,args});
  if(name==='agent_browser_control')return{control:{mode:args.action==='take'?'user':args.action==='stop'?'stopping':'agent',generation:args.generation+1,instance:'fixture-worker',controller:args.action==='take'?args.controller:'',sequence:0}};
  if(failInput)throw new Error('Synthetic lost response');
  return {...initialFrame,sequence:requests.length+2};
 };
 let root;
 await act(async()=>{root=renderer.create(React.createElement(BrowserViewer,{id:'application-run',requestBrowser,openStream}));});
 const press=label=>root.root.findByProps({accessibilityLabel:label}).props.onPress();
 await act(async()=>{press('Open browser');});assert.equal(opened,1);
 await act(async()=>{state('connected');receive({control:{mode:'agent',generation:0,instance:'fixture-worker',controller:'',sequence:0},server_time:now(),observed_at:now(),frame:initialFrame});});
 await act(async()=>{await press('Take control');});
 assert.equal(requests[0].args.instance,'fixture-worker');assert.equal(requests[0].args.generation,0);
 let canvas=root.root.findByProps({accessibilityLabel:'Live remote browser'});
 await act(async()=>{canvas.props.onLayout({nativeEvent:{layout:{width:200,height:400}}});canvas.props.onPanResponderGrant({nativeEvent:{locationX:100,locationY:200}});canvas.props.onPanResponderRelease({}, {dx:0,dy:0});await wait(5);});
 assert.deepEqual([requests[1].args.event.x,requests[1].args.event.y],[50,100]);assert.equal(requests[1].args.event.sequence,1);
 await act(async()=>{root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.onChangeText('abc');await wait(130);});
 assert.equal(requests[2].args.event.type,'text');assert.equal(requests[2].args.event.text,'abc');assert.equal(requests[2].args.event.sequence,2);
 await act(async()=>{await press('Resume agent');});assert.equal(requests[3].args.action,'resume');
 await act(async()=>{receive({control:{mode:'user',generation:1,instance:'fixture-worker',controller:requests[0].args.controller,sequence:2},server_time:now(),observed_at:now(),frame:{...initialFrame,sequence:1}});});
 assert.equal(root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.editable,false,'late control event cannot restore an old controller');
 await act(async()=>{await press('Take control');});
 failInput=true;
 await act(async()=>{root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.onChangeText('lost');await wait(130);});
 const owner=requests[0].args.controller;
 await act(async()=>{state('connected');receive({control:{mode:'user',generation:3,instance:'fixture-worker',controller:owner,sequence:0},server_time:now(),observed_at:now(),frame:{...initialFrame,sequence:20}});});
 assert.equal(root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.editable,false,'heartbeat must not unlock unconfirmed input');
 assert.equal(root.root.findAllByProps({accessibilityLabel:'Resume agent'}).length,0);
 await act(async()=>{await press('Take control');});failInput=false;
 assert.equal(root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.editable,true,'new generation recovers uncertain input');
 await act(async()=>{press('Close');});assert.equal(closed,1);assert.equal(requests.length,7,'closing never stops or resumes a task');
 await act(async()=>{root.unmount();});
}
(async()=>{await streamTests();await viewerTests();console.log('Native stream and shared viewer tests passed.');})().catch(e=>{console.error(e);process.exitCode=1;});
