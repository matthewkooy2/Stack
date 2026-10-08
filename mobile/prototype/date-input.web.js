import React from 'react';
import {TextInput} from 'react-native';
import {base} from './design';
export function DateInput({label,value,disabled,onChange,mode,style}){return <TextInput accessibilityLabel={label} value={value} editable={!disabled} onChangeText={onChange} placeholder={mode==='date'?'YYYY-MM-DD':'YYYY-MM-DDTHH:mm'} style={[base.input,style]}/>;}
