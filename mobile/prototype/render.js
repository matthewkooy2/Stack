import React from 'react';
let templates;
export function installTemplates(value){templates=value;}
export function renderTemplate(name,values){
 if(!templates?.[name])throw new Error('Missing shared Jac view: '+name);
 // Static Jac templates have no hooks; resolve their tree for sibling layout.
 const tree=templates[name]({v:values});
 return React.isValidElement(tree)&&values.s0?.key!==undefined?React.cloneElement(tree,{key:values.s0.key}):tree;
}
