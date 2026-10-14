import React from 'react';
import {View,Text} from 'react-native';
import DateTimePicker from '@react-native-community/datetimepicker';
const localISO=date=>new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16);
export function DateInput({label,value,mode,disabled,onChange,style}){const parsed=new Date(mode==='date'&&value?value+'T12:00':value),date=Number.isNaN(parsed.getTime())?new Date():parsed;return <View style={[style,{gap:8,alignItems:'flex-start'}]}><Text>{value?date.toLocaleString():`Choose ${label.toLowerCase()}`}</Text><DateTimePicker accessibilityLabel={label} value={date} mode={mode} display="compact" disabled={disabled} onChange={(_,next)=>{if(next)onChange(localISO(next).slice(0,mode==='date'?10:16));}}/></View>;}
