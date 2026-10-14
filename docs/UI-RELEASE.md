# Native UI release

The mobile entry renders the shared redesigned Jobs, Applications, Network and Resume screens. General Prep uses the cream audio/text workflow from `buttery-goodness`, with directional transitions, staggered reveals, press feedback, recording and coaching activity motion, and Reduce Motion support. Existing application-specific interview tools remain available.

TestFlight and other `STACK_BUILD_MODE=release` builds always use real authentication and live feature data at the validated `STACK_API_URL`. A release rejects mock auth, mock data, and a different auth origin. Development previews retain explicit mock mode. The build stages the shared controllers, motion helpers, Clipboard module, app icon and Stack Speech module before bundling.

The auth transport accepts Stack username/password and the existing Google handoff. Apple sign-in remains unavailable. Existing accounts may need to sign in again because the redesigned app stores its session under an origin-scoped key. An older backend without `auth_google_status` still permits Stack password login.

Checks: `node tests/auth-build-config.cjs`, `node tests/live-contract.cjs`, `node tests/live-mapping.cjs`, `node tests/prep-session-compat.cjs`, Jac checks and native compilation. With installed native dependencies: `node tests/prep-motion.cjs`, `node tests/prep-native.cjs`, `node tests/transcription-native.cjs`. After an iOS export with source maps: `node tests/mobui-native-graph.cjs` and `STACK_API_URL=<build origin> node tests/mobui-auth-native-graph.cjs`.

Browser motion and native harness checks use controlled OS and coaching responses. Physical iPhone animation feel, microphone capture and attended account sign-in require device acceptance.
