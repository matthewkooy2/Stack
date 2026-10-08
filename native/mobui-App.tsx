import React from 'react';
import {StatusBar} from 'react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
// @ts-expect-error Jac's staged runtime has no TypeScript declarations.
import {JacClientErrorBoundary,ErrorFallback,__jacReactErrorHandler,__jacInstallErrorHandlers} from '@jac/runtime';
// @ts-expect-error Compiled shared Jac entry.
import {app as JacApp} from '../jac-app';
__jacInstallErrorHandlers();
// Safe areas and keyboard avoidance are owned once by the shared RootFrame. Gesture Handler needs one root
// for the swipe card's UI-thread gestures.
export default function App(){return <GestureHandlerRootView style={{flex:1}}><JacClientErrorBoundary FallbackComponent={ErrorFallback} onError={__jacReactErrorHandler}><StatusBar barStyle="dark-content"/><JacApp/></JacClientErrorBoundary></GestureHandlerRootView>;}
