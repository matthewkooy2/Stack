# Resume upload: approved stacking icon

Source: `claude/ios-sim`, based on the October 23 conversation's approved animated preview.
`approved-motion.html` preserves that preview; `approved-still.png` shows its settled state.

The first-use Resume screen has a centered “Upload your resume” heading and one upload action:
five paper sheets stack back-to-front, then remain still. The icon opens the existing PDF file picker.
The file limit remains 10 MB. Upload progress and failure stay on the same screen; success opens the
existing populated Resume view. Profile access remains available. No other Resume workflows are redesigned.

The native icon uses the coin S's spring response of 0.5, damping fraction of 0.72, and 50 ms layer stagger.
Reduce Motion shows the assembled stack immediately. The animation waits for any launch hold to finish.

On a device with saved resumes, use Motion Lab → Preview → Resume upload; tapping that preview icon
replays without uploading or modifying account data. The real first-use icon opens the file picker.
The debug `--screen-flow=resume-upload` fixture renders the real empty-state path against an offline account.

Phone command: `bash scripts/ios-phone.sh`. The script builds, signs, installs and launches the app.
Checks run: structural checks, a signed device build, phone installation and launch, and a simulator build.
No resume was uploaded and no account data changed during verification.
