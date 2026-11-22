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


## V0.3.0 audio-stream mode (experimental)

`app_process / dev.popowk.simai.probe.Main serve <64hex-secret>` creates a one-session (max 180s) Android 13 audio server at `127.0.0.1:18765`. The Mac uses a separate user-authorized ADB TCP forward and sends `SIMAI_AUDIO_1 <secret>\n`. If the phone is in real call audio mode, the server answers `OK\n` and exchanges simultaneous raw PCM16 mono LE 16 kHz, in exact 640-byte/20ms frames. Android's AudioRecord source is VOICE_DOWNLINK; its AudioTrack comes from AudioManager's getCallUplinkInjectionAudioTrack. The Mac's uplink starts as *silence*, and microphone use requires another explicit consent. Caller and helper audio is only in volatile memory. No raw PCM/secret/number in logs, no external IP listener, and no automatic call answering. If one direction closes, the entire preview session stops. OEM support, latency and intelligibility must be verified on the actual handset.


## V0.3.1 helper start diagnostics

A short handshake error is now returned from the local PCM stream socket when possible. Responses are `OK`, `ERR NOT_IN_CALL`, `ERR AUTH` or `ERR INIT_<PHASE>_<ERROR_CATEGORY>` (uppercase ASCII only). No exception text, stack trace, PCM data, caller identity or session secret is included. Mac strictly validates code syntax before writing diagnostics. If the helper exits before opening the socket, the Mac reports `AUDIO_PORT_TIMEOUT` / `AUDIO_HANDSHAKE_NO_RESPONSE`. Pushing the temporary Dex helper is retried once on transient ADB issues. No auto-answer or persistent audio recording.
