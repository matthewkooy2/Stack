// Shared swipe contract. The card's motion never goes through React state: only the coarse
// "intent" (nothing / leaning / ready to release) is reported, so a drag re-renders the screen
// at most when that changes, not on every pointer move.
export const SWIPE_THRESHOLD=90,TILT_RANGE=252,LEAVE_DISTANCE=480,LEAVE_MS=280,RETURN_MS=180,ACTIVATE_DX=16;
// Representative drag values for each intent: 0 (idle), ±45 (leaning), ±90 (past the threshold).
// Runs inside the gesture worklet on the UI thread, hence the directive.
export const intentOf=dx=>{'worklet';return dx===0?0:Math.abs(dx)>=SWIPE_THRESHOLD?(dx>0?SWIPE_THRESHOLD:-SWIPE_THRESHOLD):(dx>0?SWIPE_THRESHOLD/2:-SWIPE_THRESHOLD/2);};
export const leavingOf=spec=>spec.variant?.match(/leave-(save|pass)/)?.[1]||'';
export const heldDragOf=spec=>parseFloat(spec.style?.['--drag'])||0;
