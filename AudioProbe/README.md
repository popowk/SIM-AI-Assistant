# Android 13+ cellular audio compatibility probe (not a telephone recorder)

First-stage diagnostic only. It does not transmit, store or export raw audio.
Invoked explicitly from Mac SIM AI Assistant via a user-approved ADB connection.

- \`info\`: checks SDK level, current AudioManager mode, telephony output device and PSTN call interceptability. Unknown / false is not definitive OEM compatibility evidence.
- \`downlink\`: **only during an already-connected, consented real call**, attempts AudioRecord VOICE_DOWNLINK for roughly 2.2 seconds and returns frame count, RMS and peak amplitude. No audio samples leave the process. Nonzero data does not prove the remote caller's speech was captured: test while they speak, and verify empirically in the later live-streaming phase.
- \`uplink\`: **only during a confirmed, consented real call**, attempts USAGE_CALL_ASSISTANT + setForCallRedirection AudioTrack and emits two modest ~660 Hz tones totaling ~1 second. A successful write is NOT proof that the remote party heard it; obtain verbal confirmation and log it separately.
- Both active tests refuse calls if AudioManager is not reporting call audio mode. No auto-answer, remote command endpoint, persistent daemon, persistent buffers, or audio logging.

The helper runs with the standard Android ADB shell user through \`app_process\`, not root and not elevated via Shizuku. No Android phone call permissions or protected APIs are bypassed; Android OEM policy may reject the request. The phone stays on Android 13/OriginOS as-is.

The Mac bundles the dex jar compiled by \`Scripts/build-audio-probe.sh\` and pushes it to \`/data/local/tmp/simai-audio-probe.jar\` when the user starts a test. The helper exits after each action. Use only on the user's own phone and only when the other party has agreed to the sound test.

This uses the *architectural approach* described by PhoneBridge (ADB + app_process + Android call redirection), with thanks and license information in THIRD_PARTY_NOTICES.md.
