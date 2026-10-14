// Native controls used by the shared Jac view trees. No DOM, WebView or Expo DOM.
import React,{createContext,useContext,useEffect,useRef,useState} from 'react';
import {View,Text,Pressable,TextInput,ScrollView,Modal,Switch,KeyboardAvoidingView,Platform,Linking,PanResponder,Animated,BackHandler,useWindowDimensions} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {base,tokens,nativeStyle,isSkeleton,chainEntry,needsHas} from './design';
import {Gradient,Wave,usePulse} from './motion';
import {DateInput} from './date-input';
import {SwipeCard} from './swipe';
import {services} from './services';
import {copyHidden,copyText,copyChildren,soleText} from './live-copy';
const Context=createContext({chain:[],text:{},disabled:false,masked:false});
const Viewport=createContext({width:390,height:844});
const Position=createContext(null);
const Form=createContext(null),Select=createContext(null);
let backActions=[],backFallback=()=>false,activeOwner=null;
export const setBackFallback=fn=>{backFallback=fn;};
// Tabs stay mounted while hidden; a hidden tab's back actions must not answer the system back gesture.
const Owner=createContext(null);
export const TabOwner=Owner.Provider;
export const setActiveOwner=name=>{activeOwner=name;};
export function performBack(){for(let i=backActions.length-1;i>=0;i--){const item=backActions[i];if(!item.owner||item.owner===activeOwner){item.fn();return true;}}return backFallback();}
function useBack(fn,enabled){const owner=useContext(Owner),current=useRef(fn);current.current=fn;useEffect(()=>{if(!enabled)return;const item={owner,fn:()=>current.current?.()};backActions.push(item);return()=>{backActions=backActions.filter(x=>x!==item);};},[enabled,owner]);}
const event=(value,checked)=>({target:{value,checked},currentTarget:{},defaultPrevented:false,preventDefault(){this.defaultPrevented=true;},stopPropagation(){}});
const classLists=new Map();
function classList(value){let list=classLists.get(value);if(!list){list=value.split(/\s+/).filter(Boolean);if(classLists.size>4000)classLists.clear();classLists.set(value,list);}return list;}
const hasClass=(items,name)=>React.Children.toArray(items).some(c=>React.isValidElement(c)&&(classList(c.props.variant+' '+(c.props.spec?.variant||'')).includes(name)||hasClass(c.props.children,name)));
function useNode(kind,variant,spec,children){
 const parent=useContext(Context),variants=classList(variant+' '+(spec.variant||''));
 const position=useContext(Position);if(position&&position.depth===parent.chain.length&&spec._index===undefined)spec={...spec,...position.spec};
 const viewport=useContext(Viewport);
 // `:has()` rules apply to a few card/entry nodes only; scanning every subtree for each node is quadratic.
 const has=needsHas(kind,variants),hasDecision=!!(has&1)&&hasClass(children,'decision-body'),hasMask=!!(has&2)&&hasClass(children,'net-mask');
 const chain=[...parent.chain,chainEntry(parent.chain,{kind,variants,spec,hasDecision,hasMask,viewportHeight:viewport.height})],styles=nativeStyle(chain,spec.style);
 const disabled=parent.disabled||!!spec.disabled||spec.inert===true||spec.inert==='';
 const ownMask=!parent.masked&&(isSkeleton(chain)||variants.some(v=>['net-mask','skeleton-value','net-input-mask','resume-input-placeholder'].includes(v))||(['input','textarea'].includes(kind)&&styles.meta._gradient?.includes('#e8ebf2')));
 const masked=parent.masked||ownMask;
 const heading=/^h[1-6]$/.test(kind),defaults=heading?{fontSize:({h1:32,h2:24,h3:18.72,h4:16,h5:13.28,h6:10.72})[kind],fontWeight:'700'}:['strong','b'].includes(kind)?{fontWeight:'700'}:kind==='small'?{fontSize:(parent.text.fontSize||16)*.8333}:{};
 const text={fontSize:16,color:tokens.ink,...parent.text,...defaults,...styles.text};
 for(const [key,value] of Object.entries(styles.layout)){if(value==='currentColor')styles.layout[key]=text.color;else if(typeof value==='string'&&/^[\d.]+em$/.test(value))styles.layout[key]=parseFloat(value)*text.fontSize;}
 const lineFactor=styles.text._lineHeight??parent.lineFactor;delete text._lineHeight;text.lineHeight=styles.text.lineHeight||(lineFactor?text.fontSize*lineFactor:undefined);
 const margin=['p','ul','ol'].includes(kind)?text.fontSize:heading?text.fontSize*({h1:.67,h2:.83,h3:1,h4:1.33,h5:1.67,h6:2.33})[kind]:0;
 styles.layout={...(margin?{marginTop:margin,marginBottom:margin}:{}),...styles.layout};
 if(kind==='legend'&&parent.chain.some(n=>n.variants.includes('jobs-sheet')))styles.layout.width='100%';
 if(parent.styles?.meta._columns){const count=parent.styles.meta._columns,gap=parent.styles.layout.gap||0;styles.layout={...styles.layout,width:((parent.gridWidth||viewport.width-46)-gap*(count-1))/count};}
 // Block-flow margins collapse in the reference. Flex/grid spacing never does.
 const previous=spec._previous;
 if(previous&&!['flex','inline-flex','grid'].includes(parent.styles?.meta._display)){
  const prior=nativeStyle([...parent.chain,previous],previous.spec.style);
  const psize=prior.text.fontSize||parent.text.fontSize||16;
  const defaultMargin=['p','ul','ol'].includes(previous.kind)?psize:/^h[1-6]$/.test(previous.kind)?({h1:21.44,h2:19.92,h3:18.72,h4:21.28,h5:22.18,h6:25})[previous.kind]:0;
  const bottom=Number(prior.layout.marginBottom??defaultMargin),top=Number(styles.layout.marginTop||0);
  if(bottom>0&&top>0)styles.layout.marginTop=top-Math.min(top,bottom);
 }
 if(kind==='li'&&spec._index===spec._count&&parent.styles?.layout.marginBottom>0)styles.layout.marginBottom=Math.max(0,(styles.layout.marginBottom||0)-parent.styles.layout.marginBottom);
 const marker=kind!=='li'?'':parent.styles?.meta._listStyle==='none'?(chain.some(n=>n.variants.includes('decision-section'))?'· ':''):parent.chain.at(-1)?.kind==='ol'?`${spec._typeIndex||spec._index||1}. `:'• ';
 return {chain,text,lineFactor,disabled,masked,ownMask,styles,variants,label:parent.label,marker};
}
function SkeletonShape({node}){
 const pulse=usePulse(true),after=nativeStyle(node.chain,undefined,'after'),style=after.layout;
 if(node.variants.includes('resume-input-placeholder'))return <Animated.View pointerEvents="none" style={{position:'absolute',left:14,top:'50%',width:'60%',height:10,transform:[{translateY:-5}],backgroundColor:'#e8ebf2',borderRadius:2,opacity:pulse}}/>;
 if(!Object.keys(style).length)return null;
 const gradient=after.meta._gradient;
 const common={position:'absolute',pointerEvents:'none',backgroundColor:tokens.skeleton,borderRadius:4,...style};
 if(gradient?.includes('92%'))return <View pointerEvents="none" style={{position:'absolute',inset:0}}><Animated.View style={{...common,left:0,top:'6.5%',height:'35%',width:'92%',opacity:pulse}}/><Animated.View style={{...common,left:0,top:'55.25%',height:'35%',width:'57%',opacity:pulse}}/></View>;
 if(gradient?.includes('80% 10px'))return <View pointerEvents="none" style={{position:'absolute',inset:0}}><Animated.View style={{...common,left:0,top:3,height:10,width:'80%',opacity:pulse}}/><Animated.View style={{...common,left:0,top:undefined,bottom:3,height:7,width:'100%',opacity:pulse}}/></View>;
 if(gradient?.startsWith('repeating-'))return <View pointerEvents="none" style={{...common,overflow:'hidden',backgroundColor:'transparent'}}>{Array.from({length:24},(_,i)=><Animated.View key={i} style={{height:8,marginBottom:14,backgroundColor:'#e8ebf2',opacity:pulse}}/>)}</View>;
 return <Animated.View pointerEvents="none" style={[{left:0,right:0,top:'15%',bottom:'15%'},common,{opacity:pulse}]}/>;
}
function flatten(children,prefix=''){const items=React.Children.toArray(children).flatMap((c,i)=>{if(!React.isValidElement(c))return [c];const key=prefix+(c.key??i);return c.type===React.Fragment||c.type===StackFragment?flatten(c.props.children,key+'/'):[React.cloneElement(c,{key})];}),result=[];for(const item of items){if(['string','number'].includes(typeof item)&&['string','number'].includes(typeof result.at(-1)))result[result.length-1]=String(result.at(-1))+item;else result.push(item);}return result;}
function componentKind(c){const name=c.props?.spec?.component?.name;return ({Entry:'button',Field:'label',Fold:'details',Editable:'div',Empty:'div',Announcement:'span',PublicProfiles:'main',ResumeTools:'div',Score:'div',MockInterview:'article',InterviewFeedback:'article'})[name]||'svg';}
function content(children,style,masked=false){
 const items=flatten(children),elements=items.filter(React.isValidElement),types={};
 const kindOf=c=>c.type===StackComponent?componentKind(c):c.props.kind||'div';
 for(const c of elements){const k=kindOf(c);types[k]=(types[k]||0)+1;}
 let index=0,previous=null;const counts={};
 return items.map((c,i)=>{if(typeof c==='string'||typeof c==='number')return <Text key={'text-'+i} aria-hidden={masked} accessible={!masked} style={[base.text,style,masked&&{color:'transparent',backgroundColor:tokens.skeleton,borderRadius:4}]}>{typeof c==='string'?copyText(c):c}</Text>;
  if(!React.isValidElement(c))return c;const k=kindOf(c);counts[k]=(counts[k]||0)+1;
  const spec={...c.props.spec,_index:++index,_count:elements.length,_typeIndex:counts[k],_typeCount:types[k],_previous:previous};
  const componentVariant=({Field:'net-field',Fold:'net-fold',Entry:'net-entry'})[c.props.spec?.component?.name]||'';
  previous={kind:k,variants:(c.props.variant+' '+(c.props.spec?.variant||'')+' '+componentVariant).split(/\s+/).filter(Boolean),spec};
  return React.cloneElement(c,{spec});
 });
}
function a11y(spec){return {'aria-hidden':spec['aria-hidden']===true||spec['aria-hidden']==='true',accessibilityElementsHidden:spec['aria-hidden']===true||spec['aria-hidden']==='true',importantForAccessibility:spec['aria-hidden']===true||spec['aria-hidden']==='true'?'no-hide-descendants':'auto',accessibilityLabel:spec['aria-label'],accessibilityRole:spec.role==='tab'?'tab':spec.role==='switch'?'switch':spec.role==='alert'?'alert':undefined,accessibilityLiveRegion:spec.role==='status'?'polite':spec.role==='alert'?'assertive':undefined,accessibilityState:{disabled:!!spec.disabled,selected:spec['aria-selected']??!!spec['aria-current'],checked:spec['aria-checked']??spec['aria-pressed'],expanded:spec['aria-expanded'],busy:!!spec['aria-busy']},testID:spec['data-testid']};}
export function StackFragment({children}){const context=useContext(Context);return <>{content(children,context.text,context.masked)}</>;}
export function StackComponent({spec,children}){if(spec.omit)return null;const {component:Component,_index,_count,_typeIndex,_typeCount,_previous,...props}=spec;const parent=useContext(Context);if(typeof Component==='function')return <Position.Provider value={{depth:parent.chain.length,spec:{_index,_count,_typeIndex,_typeCount,_previous}}}><Component {...props}>{children}</Component></Position.Provider>;return <StackIcon spec={spec}>{children}</StackIcon>;}
function StackIcon({spec,children}){const {component:Component,_index,_count,_typeIndex,_typeCount,_previous,...props}=spec;const context=useNode('svg','',spec);if(context.masked)return <View accessibilityElementsHidden style={{width:props.size||22,height:props.size||22,borderRadius:5,backgroundColor:tokens.line}}/>;return <View style={[{width:props.size||24,height:props.size||24,flexShrink:0,alignSelf:context.text.textAlign==='center'?'center':undefined},context.styles.layout]}><Component {...props} color={props.color||context.text.color} disabled={context.disabled||props.disabled}>{children}</Component></View>;}
export function StackText({kind,variant='',spec={},children}){
 const node=useNode(kind,variant,spec,children),heading=/^h\d$/.test(kind);
 if(spec.omit||copyHidden(soleText(children)))return null;
 children=copyChildren(children);
 const defaults=heading?{fontSize:kind==='h1'?30:kind==='h2'?23:16,fontWeight:'600'}:kind==='strong'||kind==='b'?{fontWeight:'600'}:{};
 const blockChildren=flatten(children).some(c=>React.isValidElement(c)&&c.props.kind&&(/^(h[1-6]|p|div|section|ul|ol|dl)$/.test(c.props.kind)||nativeStyle([...node.chain,{kind:c.props.kind,variants:(c.props.variant+' '+(c.props.spec?.variant||'')).split(/\s+/).filter(Boolean),spec:c.props.spec||{}}]).meta._display==='block'));
 if(kind==='li'&&!blockChildren&&!node.masked)return <Context.Provider value={node}><View style={node.styles.layout}>{node.marker&&<Text style={[base.text,node.text,{position:'absolute',left:node.chain.some(n=>n.variants.includes('decision-section'))?0:-18,top:node.styles.layout.paddingTop||0}]}>{node.marker}</Text>}<Text style={[base.text,node.text]}>{children}</Text></View></Context.Provider>;
 if(blockChildren||['flex','grid'].includes(node.styles.meta._display))return <Context.Provider value={node}><View {...a11y(spec)} accessibilityRole={heading?'header':undefined} style={node.styles.layout}>{node.marker&&<Text style={[base.text,node.text,{position:'absolute',left:-18,top:node.styles.layout.paddingTop||0}]}>{node.marker}</Text>}{node.ownMask?<><View style={{opacity:0}}>{content(children,node.text)}</View><SkeletonShape node={node}/></>:content(children,node.text,node.masked)}</View></Context.Provider>;
 // Text may contain native controls (e.g. a heading's close button); use a row in that case.
 const text=<Text ref={spec.ref} {...a11y(spec)} aria-hidden={node.masked||spec["aria-hidden"]===true||spec["aria-hidden"]==="true"} selectable={!node.masked} accessibilityRole={heading?'header':spec.role==='alert'?'alert':undefined} accessibilityElementsHidden={node.masked} importantForAccessibility={node.masked?'no-hide-descendants':'auto'} style={[base.text,defaults,!node.ownMask&&node.styles.layout,node.text,node.masked&&{opacity:0}]}>{node.marker}{children}</Text>;
 return <Context.Provider value={node}>{node.ownMask?<View style={node.styles.layout} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">{text}<SkeletonShape node={node}/></View>:text}</Context.Provider>;
}
export function StackLayout({kind,variant='',spec={},children}){
 const node=useNode(kind,variant,spec,children),sheet=node.variants.includes('jobs-sheet-backdrop');
 const [gridWidth,setGridWidth]=useState(0);node.gridWidth=gridWidth;
 if(kind==='label')node.label=React.Children.toArray(children).filter(c=>typeof c==='string').join(' ').trim();
 const dismiss=()=>spec.onClick?.(event());useBack(dismiss,sheet);
 if(spec.omit||copyHidden(soleText(children)))return null;
 children=copyChildren(children);
 if(kind==='span'&&!['flex','inline-flex','grid'].includes(node.styles.meta._display)&&flatten(children).every(c=>['string','number'].includes(typeof c)))return <StackText kind={kind} variant={variant} spec={spec}>{flatten(children)}</StackText>;
 if(kind==='br')return <Text>{'\n'}</Text>;
 if(sheet)return <Modal transparent animationType="slide" visible onRequestClose={dismiss} accessibilityViewIsModal><SafeAreaView style={base.backdrop} edges={['top','bottom']}><Pressable accessibilityLabel="Dismiss panel" onPress={dismiss} style={{flex:1}}/><KeyboardAvoidingView behavior={Platform.OS==='ios'?'padding':undefined} style={base.sheet}><ScrollView keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag"><Context.Provider value={node}>{content(children,node.text)}</Context.Provider></ScrollView></KeyboardAvoidingView></SafeAreaView></Modal>;
 const classes=node.variants;
 const isRoot=classes.includes('jobs-preview'),row=kind==='header'||kind==='nav';
 let layout={...node.styles.layout};
 if(isRoot){layout={...layout,flex:1,height:undefined,minHeight:0};}
 if(classes.includes('application-focus-page'))layout={...layout,flex:1,height:undefined,minHeight:0};
 if(classes.includes('interviewer-stage')||classes.includes('interviewer-orb')){const orb=classes.includes('interviewer-orb');return <View style={[layout,{overflow:orb?'visible':'hidden'}]}>{orb&&<View pointerEvents="none" style={{position:'absolute',top:-12,left:-12,right:-12,bottom:-12,borderRadius:999,backgroundColor:'#ffffff40'}}/>}<View pointerEvents="none" style={{position:'absolute',inset:0,borderRadius:orb?999:0,overflow:'hidden'}}><Gradient orb={orb}/></View><Context.Provider value={node}>{content(children,node.text)}</Context.Provider></View>;}
 if(classes.includes('interviewer-wave'))return <Wave active={node.chain.some(n=>n.variants.includes('is-playing'))}/>;
 if(kind==='i'&&node.chain.at(-2)?.variants.includes('interview-setting-row'))return <View style={layout}><View style={{width:15,height:15,borderRadius:8,backgroundColor:'white',alignSelf:classes.includes('on')?'flex-end':'flex-start'}}/></View>;
 if(classes.includes('jobs-wordmark'))layout={...layout,position:'absolute',left:'50%',transform:[{translateX:-32}]};
 if(classes.includes('jobs-toast'))layout={...layout,left:undefined,alignSelf:'center'};
 if(classes.includes('sheet-handle'))layout={...layout,alignSelf:'center',left:undefined};
 if(classes.includes('jobs-sheet'))layout={...layout,maxHeight:undefined};
 if(node.styles.meta._columns)layout={...layout,flexDirection:'row',flexWrap:'wrap'};
 if(classes.includes('application-row-status'))return <View style={[layout,{backgroundColor:'transparent',flexDirection:'row',alignItems:'center'}]}><View style={{width:4,height:4,borderRadius:2,backgroundColor:node.masked?tokens.line:node.text.color}}/>{content(children,node.text,node.masked)}</View>;
 if(kind==='fieldset')layout={borderWidth:0,padding:0,...layout};
 if(kind==='fieldset'&&node.chain.some(n=>n.variants.includes('jobs-sheet')))layout={...layout,flexDirection:'row',flexWrap:'wrap'};
 if(kind==='ul'||kind==='ol')layout={paddingLeft:40,...layout};
 if(kind==='span'&&!node.styles.meta._display){const block=flatten(children).some(c=>['small','h3'].includes(c?.props?.kind));layout={flexDirection:block?'column':'row',flexWrap:block?'nowrap':'wrap',alignItems:block?'stretch':'center',...layout};}
 if(classes.includes('jobs-loading-announcement'))return <Text accessibilityRole="text" accessibilityLiveRegion="polite" style={base.announcement}>{children}</Text>;
 const contents=<Context.Provider value={node}>{node.ownMask?<><View style={{opacity:0}}>{content(children,node.text,true)}</View><SkeletonShape node={node}/></>:content(children,node.text,node.masked)}</Context.Provider>;
 if(classes.includes('interview-transcript')){const {maxHeight,marginTop,marginBottom,...inner}=layout;return <ScrollView style={{maxHeight,marginTop,marginBottom,flexShrink:0}} contentContainerStyle={inner}>{contents}</ScrollView>;}
 if(classes.includes('application-workflow')){const {height,maxHeight,overflow,flex,...body}=layout;return <Context.Provider value={node}><ScrollView ref={spec.ref} stickyHeaderIndices={[0]} style={{flex:1,minHeight:0}} contentContainerStyle={{...body,paddingBottom:28}} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">{content(children,node.text,node.masked)}</ScrollView></Context.Provider>;}
 if(classes.includes('opportunity'))return <SwipeCard spec={spec} a11y={a11y(spec)} disabled={node.disabled} style={[{flex:1},layout]}>{contents}</SwipeCard>;
 if(classes.includes('decision-body'))return <ScrollView contentContainerStyle={{flexGrow:1}} style={{flex:1,minHeight:0}}>{contents}</ScrollView>;
 return <View ref={spec.ref} {...a11y(spec)} onLayout={node.styles.meta._columns?e=>setGridWidth(e.nativeEvent.layout.width):undefined} style={[row&&{flexDirection:'row',alignItems:'center'},layout]}>{contents}</View>;
}
export function StackScroll({kind,variant='',spec={},children}){
 const node=useNode(kind,variant,spec,children);let layout={...node.styles.layout};
 if(node.variants.includes('jobs-deck'))return <StackLayout kind={kind} variant={variant} spec={spec}>{children}</StackLayout>;
 const {padding,paddingHorizontal,paddingVertical,paddingTop,paddingBottom,paddingLeft,paddingRight,gap,...outer}=layout;
 return <Context.Provider value={node}><ScrollView ref={spec.ref} {...a11y(spec)} style={[{flex:1},outer]} contentContainerStyle={{padding,paddingHorizontal,paddingVertical,paddingTop,paddingBottom:paddingBottom||24,paddingLeft,paddingRight,gap,flexGrow:1}} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">{content(children,node.text,node.masked)}</ScrollView></Context.Provider>;
}
export function StackButton({kind,variant='',spec={},children}){
 const node=useNode(kind,variant,spec,children),form=useContext(Form);
 const activate=()=>{if(node.disabled)return;const e=event();spec.onClick?.(e);if(e.defaultPrevented)return;if(kind==='a'&&spec.href)Linking.openURL(spec.href);else if(spec.type==='submit'||form&&spec.type!=='button')form?.(e);};
 const label=spec['aria-label']||'';useBack(activate,!node.disabled&&/^(Back|Exit|Close|Hide day)/i.test(label));
 if(spec.omit)return null;
 let layout={...node.styles.layout};
 const parent=node.chain.at(-2);
 if(kind==='summary')layout={justifyContent:'flex-start',...layout};
 if(parent?.variants.includes('resume-templates'))layout={...layout,flexDirection:'column',alignItems:'stretch',justifyContent:'flex-start'};
 if(parent?.variants.includes('jobs-nav'))layout={...layout,flex:1,width:undefined};
 if(parent?.variants.includes('resume-tabs')&&spec['aria-selected'])layout={...layout,borderBottomWidth:2,borderBottomColor:'#8193b5'};
 if(parent?.variants.includes('application-filters')&&spec['aria-pressed'])layout={...layout,borderBottomWidth:2,borderBottomColor:tokens.ink};
 if(node.variants.includes('sheet-close'))layout={...layout,zIndex:2};
 const text={...node.text};
 const hitSlop={top:Math.max(0,(44-(Number(layout.height)||44))/2),bottom:Math.max(0,(44-(Number(layout.height)||44))/2),left:Math.max(0,(44-(Number(layout.width)||44))/2),right:Math.max(0,(44-(Number(layout.width)||44))/2)};
 const alignment=node.styles.meta._display==='flex'||node.styles.meta._display==='inline-flex'?{justifyContent:'flex-start',alignItems:'stretch'}:{};
 return <Context.Provider value={{...node,text}}><Pressable ref={spec.ref} {...a11y({...spec,disabled:node.disabled})} hitSlop={hitSlop} accessibilityRole={spec.role==='tab'?'tab':spec.role==='switch'?'switch':kind==='a'?'link':'button'} disabled={node.disabled} onPress={activate} style={({pressed})=>[base.button,alignment,layout,node.disabled&&layout.opacity===undefined&&base.disabled,pressed&&{opacity:0.65}]}>{node.ownMask?<><View style={{opacity:0}}>{content(children,text,true)}</View><SkeletonShape node={node}/></>:content(children,text,node.masked)}</Pressable></Context.Provider>;
}
export function StackInput({kind,variant='',spec={}}){
 const node=useNode(kind,variant,spec),file=spec.type==='file',checkbox=spec.type==='checkbox';
 const choose=async()=>{const result=await services.pick({accept:spec.accept});if(result)spec.onChange?.({target:{files:[result],value:''}});};
 React.useImperativeHandle(spec.ref,()=>({click:choose,focus:()=>input.current?.focus()}));const input=useRef(null);
 if(file)return spec.hidden?null:<Pressable accessibilityRole="button" accessibilityLabel={spec['aria-label']||'Choose file'} onPress={choose} style={[base.input,base.button]}><Text>Choose file</Text></Pressable>;
 if(checkbox)return <Pressable accessibilityRole="checkbox" accessibilityLabel={spec['aria-label']||node.label||'Confirm selection'} accessibilityState={{checked:!!spec.checked,disabled:node.disabled}} disabled={node.disabled} hitSlop={15} onPress={()=>spec.onChange?.(event('',!spec.checked))} style={[{width:13,height:13,borderWidth:1,borderRadius:2,borderColor:spec.checked?'#5266b6':'#777',backgroundColor:spec.checked?'#5266b6':'white',alignItems:'center',justifyContent:'center',flexShrink:0,margin:3},node.styles.layout]}>{spec.checked&&<Text style={{fontSize:11,lineHeight:11,color:'white'}}>✓</Text>}</Pressable>;
 if(spec.type==='datetime-local'||spec.type==='date')return <DateInput style={[base.input,node.styles.layout,node.text]} label={spec['aria-label']||node.label||'Date and time'} value={spec.value||''} mode={spec.type==='date'?'date':'datetime'} disabled={node.disabled} onChange={value=>spec.onChange?.(event(value))}/>;
 const field=<TextInput ref={input} {...a11y(spec)} accessibilityLabel={spec['aria-label']||node.label||spec.name||spec.placeholder} value={node.masked?'':String(spec.value??'')} placeholder={spec.placeholder} editable={!node.disabled} multiline={kind==='textarea'} autoFocus={spec.autoFocus} maxLength={spec.maxLength} keyboardType={spec.type==='email'?'email-address':spec.type==='number'?'numeric':'default'} autoCapitalize={['email','url'].includes(spec.type)?'none':'sentences'} onChangeText={value=>spec.onChange?.(event(value))} style={[base.input,kind==='textarea'&&{minHeight:40,borderWidth:1,borderColor:'#777',padding:2,textAlignVertical:'top'},node.styles.layout,node.text,node.masked&&{color:'transparent'}]}/>;
 if(node.masked)return <View style={{position:'relative',width:'100%'}}>{field}<View pointerEvents="none" style={{position:'absolute',left:14,top:'50%',width:'60%',height:10,transform:[{translateY:-5}],backgroundColor:'#e8ebf2',borderRadius:2}}/></View>;return field;
}
export function StackForm({kind,variant='',spec={},children}){return <Form.Provider value={spec.onSubmit}><StackLayout kind={kind} variant={variant} spec={spec}>{children}</StackLayout></Form.Provider>;}
export function StackDisclosure({kind,variant='',spec={},children}){
 const [open,setOpen]=useState(!!spec.open),items=React.Children.toArray(children);useEffect(()=>setOpen(!!spec.open),[spec.open]);return <Disclosure.Provider value={{open,toggle:()=>setOpen(!open)}}><StackLayout kind={kind} variant={variant} spec={{...spec,open}}>{items[0]}{open?items.slice(1):null}</StackLayout></Disclosure.Provider>;
}
const Disclosure=createContext({open:false,toggle:()=>{}});
export function StackSummary({children,spec={},variant=''}){const d=useContext(Disclosure),parent=useContext(Context),custom=parent.variants?.includes('net-fold');return <StackButton kind="summary" variant={variant} spec={{...spec,'data-testid':'native-summary',onClick:d.toggle,'aria-expanded':d.open}}>{!custom&&<Text style={{fontSize:14,marginRight:12,color:parent.text.color}}>{d.open?'⌄':'›'}</Text>}{children}</StackButton>;}
export function StackSelect({kind,variant='',spec={},children}){
 const [open,setOpen]=useState(false),[labels,setLabels]=useState({});const node=useNode(kind,variant,spec);
 useBack(()=>setOpen(false),open);
 const register=React.useCallback((value,label)=>setLabels(old=>old[value]===label?old:{...old,[value]:label}),[]);
 const select=value=>{spec.onChange?.(event(value));setOpen(false);};
 return <Select.Provider value={{open,register,select,value:String(spec.value??'')}}><Pressable {...a11y(spec)} testID="native-select" accessibilityRole="button" accessibilityLabel={spec['aria-label']||labels[String(spec.value??'')]||'Choose an option'} disabled={node.disabled} onPress={()=>setOpen(true)} style={[base.input,base.row,{minHeight:24,borderWidth:1,borderColor:'#777',paddingHorizontal:2},node.styles.layout]}><Text style={[base.text,node.text,{flex:1}]}>{labels[String(spec.value??'')]||String(spec.value??'Choose an option')}</Text><Text>⌄</Text></Pressable>{open?<Modal transparent animationType="slide" onRequestClose={()=>setOpen(false)}><SafeAreaView style={base.backdrop}><Pressable style={{flex:1}} onPress={()=>setOpen(false)} accessibilityLabel="Close choices"/><View style={base.sheet}><ScrollView contentContainerStyle={base.panel}>{children}<Pressable onPress={()=>setOpen(false)} style={base.button}><Text>Cancel</Text></Pressable></ScrollView></View></SafeAreaView></Modal>:children}</Select.Provider>;
}
export function StackOption({spec={},children}){const select=useContext(Select),label=React.Children.toArray(children).join(''),value=String(spec.value??label);useEffect(()=>{select?.register(value,label);},[value,label,select?.register]);return select?.open?<Pressable accessibilityRole="radio" accessibilityState={{checked:select.value===value}} onPress={()=>select.select(value)} style={base.option}><Text style={base.text}>{label}{select.value===value?' ✓':''}</Text></Pressable>:null;}
export function StackDocument({spec}){return <DocumentSurface uri={spec.src} label={spec.title}/>;}
let DocumentSurface=()=>null;
export function configureDocumentSurface(component){DocumentSurface=component;}
export function NativeFrame({children,backgroundColor}){
 const dimensions=useWindowDimensions();
 useEffect(()=>{if(Platform.OS==='web')return;const sub=BackHandler.addEventListener('hardwareBackPress',performBack);return()=>sub.remove();},[]);
 const pan=useRef(PanResponder.create({onMoveShouldSetPanResponder:(_,g)=>g.x0<28&&g.dx>24&&Math.abs(g.dy)<20,onPanResponderRelease:(_,g)=>{if(g.dx>70)performBack();}})).current;
 return <Viewport.Provider value={dimensions}><SafeAreaView style={[base.screen,backgroundColor?{backgroundColor}:null]} edges={['top','bottom','left','right']}><KeyboardAvoidingView style={[base.screen,backgroundColor?{backgroundColor}:null]} behavior={Platform.OS==='ios'?'padding':undefined} {...pan.panHandlers}>{children}</KeyboardAvoidingView></SafeAreaView></Viewport.Provider>;
}
