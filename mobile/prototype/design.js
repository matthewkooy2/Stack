import {StyleSheet,Platform} from 'react-native';
import rules from './style-rules.json';
import skeletons from './skeleton-selectors.json';
export const tokens={surface:'#ffffff',ink:'#202333',muted:'#657087',blue:'#4260e9',line:'#e8ebf2',skeleton:'#dfe1ee',lavender:'#f0f0f8',mint:'#e8f1eb',peach:'#f5e5db',radius:12,touch:44};
const textKeys=new Set(['color','fontSize','fontFamily','fontVariant','fontWeight','fontStyle','letterSpacing','lineHeight','textAlign','textDecorationLine','textTransform','_lineHeight']);
const droppedKeys=new Set(['boxSizing','objectFit','WebkitLineClamp','WebkitBoxOrient','verticalAlign','wordBreak','textOverflow']);
const skippedInline=new Set(['animationDelay','transform']);
const attributes=[...new Set(['disabled','checked','open',...rules.flatMap(r=>[...r.selector.matchAll(/\[([^=\]]+)/g)].map(m=>m[1]))])];

// The reference CSS is cascaded at runtime, but a node's style depends only on its chain of
// ancestors (kind, classes, a few attributes, sibling position). Everything below is built so a
// node costs one Map lookup once its chain has been seen, and a handful of rule checks the first
// time: selectors are compiled once, rules are indexed by their rarest class, and chains are
// interned in a trie so no per-call key strings are built.

// Compile one compound selector (e.g. `.opportunity.mint:has(.decision-body)`) into plain data.
function compound(source){
 let s=source;const c={noMask:false,decision:false,nots:[],attrs:[],disabled:false,checked:false,never:false,nth:[],kind:null,classes:[]};
 if(/:not\(:has\(\.net-mask\)\)/.test(s)){c.noMask=true;s=s.replace(':not(:has(.net-mask))','');}
 if(s.includes(':has(.decision-body)')){c.decision=true;s=s.replace(':has(.decision-body)','');}
 s=s.replace(/:not\(([^()]*)\)/g,(_,inner)=>{c.nots.push(compound(inner));return '';});
 for(const [,key,value] of s.matchAll(/\[([^=\]]+)(?:=["']?([^\]"']+)["']?)?\]/g))c.attrs.push([key,value]);
 s=s.replace(/\[[^\]]+\]/g,'');
 c.disabled=s.includes(':disabled');c.checked=s.includes(':checked');c.never=/:focus|:hover/.test(s);
 for(const [,which,type,value] of s.matchAll(/:(first|last|nth)-(child|of-type)(?:\(([^)]+)\))?/g))c.nth.push({which,child:type==='child',value});
 s=s.replace(/:[\w-]+(?:\([^)]*\))?/g,'');
 const kind=s.match(/^[\w-]+/);c.kind=kind?kind[0]:null;
 c.classes=[...s.matchAll(/\.([\w-]+)/g)].map(m=>m[1]);
 return c;
}
const compileSelector=selector=>selector.replace(/\s*>\s*/g,' > ').trim().split(/\s+(?![^\[]*\])/).map(part=>part==='>'?part:compound(part));
function matchCompound(c,node){
 if(!node)return false;
 if(c.noMask&&node.hasMask||c.decision&&!node.hasDecision)return false;
 for(const inner of c.nots)if(matchCompound(inner,node))return false;
 const spec=node.spec;
 for(const [key,value] of c.attrs){if(value===undefined?(spec[key]===undefined||spec[key]===false):String(spec[key])!==value)return false;}
 if(c.disabled&&!spec.disabled||c.checked&&!spec.checked||c.never)return false;
 for(const {which,child,value} of c.nth){
  const index=spec[child?'_index':'_typeIndex'],count=spec[child?'_count':'_typeCount'];
  if(!index)return false;
  if(which==='first'&&index!==1||which==='last'&&index!==count)return false;
  if(which==='nth'&&(value==='even'||value==='2n'?index%2!==0:value==='odd'?index%2!==1:index!==Number(value)))return false;
 }
 if(c.kind&&c.kind!==node.kind)return false;
 for(const name of c.classes)if(!node.variants.includes(name))return false;
 return true;
}
// Descendant matching is greedy (nearest ancestor, no backtracking), as in the original matcher.
function matchParts(parts,chain){
 let end=parts.length-1,i=chain.length-1;
 if(!matchCompound(parts[end--],chain[i--]))return false;
 while(end>=0){
  const item=parts[end--];
  if(item==='>'){if(!matchCompound(parts[end--],chain[i--]))return false;}
  else{while(i>=0&&!matchCompound(item,chain[i]))i--;if(i--<0)return false;}
 }
 return true;
}
const selectorCache=new Map();
export function matches(selector,chain){
 let parts=selectorCache.get(selector);if(!parts){parts=compileSelector(selector);selectorCache.set(selector,parts);}
 return matchParts(parts,chain);
}

// Rule index: each selector is filed under its rarest positive class (any compound), else its
// rightmost tag. A node only inspects rules whose class appears somewhere in its chain.
function buildIndex(entries){
 const frequency=new Map(),prepared=[];
 for(const entry of entries){
  const parts=compileSelector(entry.selector),compounds=parts.filter(p=>p!=='>');
  if(compounds.some(c=>c.never))continue; // :focus/:hover can never match a static render
  const classes=compounds.flatMap(c=>c.classes);
  for(const name of new Set(classes))frequency.set(name,(frequency.get(name)||0)+1);
  prepared.push({...entry,parts,classes,tag:compounds.at(-1).kind});
 }
 const index={byClass:new Map(),byTag:new Map(),any:[]};
 for(const rule of prepared){
  let key=null;for(const name of rule.classes)if(key===null||frequency.get(name)<frequency.get(key))key=name;
  const [map,name]=key!==null?[index.byClass,key]:rule.tag?[index.byTag,rule.tag]:[null,null];
  if(!map)index.any.push(rule);else{if(!map.has(name))map.set(name,[]);map.get(name).push(rule);}
 }
 return index;
}
function candidates(index,node,kind){
 const found=[];
 for(const name of node.classes){const bucket=index.byClass.get(name);if(bucket)for(const rule of bucket)found.push(rule);}
 const tagged=index.byTag.get(kind);if(tagged)for(const rule of tagged)found.push(rule);
 for(const rule of index.any)found.push(rule);
 return found;
}
const ordered=rules.map((r,i)=>({...r,order:i})).sort((a,b)=>a.weight-b.weight||a.order-b.order).map((r,rank)=>({...r,rank}));
const indexes={'':buildIndex(ordered.filter(r=>!r.pseudo))};
for(const r of ordered)if(r.pseudo&&!indexes[r.pseudo])indexes[r.pseudo]=buildIndex(ordered.filter(x=>x.pseudo===r.pseudo));
const skeletonIndex=buildIndex(skeletons.map(selector=>({selector})));

// `:has()` is only evaluated for nodes some rule could apply it to; see needsHas().
const hasCompounds=[];
for(const r of ordered)for(const part of compileSelector(r.selector))if(part!=='>'&&(part.decision||part.noMask))hasCompounds.push(part);
export function needsHas(kind,variants){
 let bits=0;
 for(const c of hasCompounds){
  if(c.kind&&c.kind!==kind||!c.classes.every(name=>variants.includes(name)))continue;
  bits|=(c.decision?1:0)|(c.noMask?2:0);
 }
 return bits;
}

// Interned chains. A trie node stands for one exact ancestor chain; per-node caches hold the
// cascade result, so identical subtrees in different places share it.
const newRoot=()=>({children:new Map(),classes:new Set(),raw:{},out:{},mask:undefined});
let root=newRoot(),trieSize=0;
const ownKey=n=>{
 const s=n.spec;let key=n.kind+'.'+n.variants.join('.')+'@'+s._index+':'+s._count+':'+s._typeIndex+':'+s._typeCount+':'+n.hasDecision+':'+n.hasMask+':'+n.viewportHeight;
 for(const name of attributes){const value=s[name];if(value!==undefined&&value!==null)key+='|'+name+':'+value;}
 return key;
};
function child(parent,entry){
 const key=ownKey(entry);let node=parent.children.get(key);
 if(!node){
  node=newRoot();for(const name of parent.classes)node.classes.add(name);for(const name of entry.variants)node.classes.add(name);
  parent.children.set(key,node);
  // Bound memory: later renders start from a fresh root; chains already built stay valid.
  if(++trieSize>30000){root=newRoot();trieSize=0;}
 }
 return node;
}
function trieOf(chain){
 let i=chain.length-1;while(i>=0&&!chain[i].trie)i--;
 let node=i<0?root:chain[i].trie;
 for(i++;i<chain.length;i++)node=child(node,chain[i]);
 return node;
}
// Build a chain entry for a node under `parentChain`, interned so later lookups are O(1).
export function chainEntry(parentChain,entry){entry.trie=child(parentChain.length?parentChain[parentChain.length-1].trie||trieOf(parentChain):root,entry);return entry;}

function resolve(node,chain,pseudo){
 const last=chain[chain.length-1],found=candidates(indexes[pseudo]||{byClass:new Map(),byTag:new Map(),any:[]},node,last.kind);
 const applicable=found.filter(r=>(!r.maxHeight||last.viewportHeight<=r.maxHeight)&&matchParts(r.parts,chain)).sort((a,b)=>a.rank-b.rank);
 const cached={};
 for(const r of applicable)Object.assign(cached,r.style);
 for(const r of applicable)Object.assign(cached,r.important);
 return cached;
}
function split(merged){
 const text={},layout={},meta={};
 for(const key in merged){
  const value=merged[key];
  if(droppedKeys.has(key))continue;
  if(key.charCodeAt(0)===95&&key!=='_lineHeight'){meta[key]=value;continue;}
  if(value!=='inherit')(textKeys.has(key)?text:layout)[key]=value;
 }
 if(text.fontWeight&&Platform.OS!=='web')text.fontWeight=String(Math.round(Number(text.fontWeight)/100)*100||400);
 return {text,layout,meta};
}
// Callers may edit `layout` in place, so every call receives its own copy of it.
export function nativeStyle(chain,inline,pseudo){
 const node=trieOf(chain),key=pseudo||'';
 let raw=node.raw[key];if(!raw)raw=node.raw[key]=resolve(node,chain,key);
 if(inline){
  const merged={...raw};
  for(const name in inline){if(name.startsWith('--')||skippedInline.has(name))continue;merged[name]=inline[name];}
  return split(merged);
 }
 let out=node.out[key];if(!out)out=node.out[key]=split(raw);
 return {text:out.text,layout:{...out.layout},meta:out.meta};
}
export const isSkeleton=chain=>{
 const node=trieOf(chain);
 if(node.mask===undefined){
  const last=chain[chain.length-1];
  node.mask=candidates(skeletonIndex,node,last.kind).some(r=>matchParts(r.parts,chain));
 }
 return node.mask;
};
export const fontFamily=Platform.OS==='web'?'Inter, system-ui, sans-serif':'System';
export const base=StyleSheet.create({
 screen:{flex:1,backgroundColor:tokens.surface},scroll:{flex:1},body:{padding:24,gap:12,paddingBottom:32},
 text:{fontFamily,fontSize:16,color:tokens.ink,flexShrink:0},button:{justifyContent:'center',alignItems:'center',flexDirection:'row'},
 input:{padding:0,borderWidth:0,fontSize:16,fontFamily,color:tokens.ink,backgroundColor:'transparent'},
 disabled:{opacity:0.4},mask:{backgroundColor:tokens.line,borderRadius:5,minHeight:14},
 backdrop:{flex:1,backgroundColor:'#1c233b55',justifyContent:'flex-end'},sheet:{maxHeight:'90%',backgroundColor:'#fff',borderTopLeftRadius:24,borderTopRightRadius:24},
 panel:{padding:24,gap:14},heading:{fontSize:25,fontWeight:'700',color:tokens.ink},row:{flexDirection:'row',alignItems:'center',gap:10},
 announcement:{position:'absolute',width:1,height:1,opacity:0,overflow:'hidden'},option:{padding:14,borderBottomWidth:1,borderBottomColor:tokens.line,minHeight:48},
 dev:{minHeight:32,backgroundColor:'#eef0f8',padding:6,alignItems:'center'},devText:{fontSize:12,color:'#465273'}
});
