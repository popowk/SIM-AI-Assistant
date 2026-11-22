# External references and acknowledgments

The cellular audio diagnostics use Android's documented/undocumented platform interfaces and the ADB-shell + \`app_process\` approach demonstrated in:

- **PhoneBridge**, https://github.com/AbinMadathil07/PhoneBridge (Apache-2.0 OR MIT, copyright its contributors)
- **scrcpy**, https://github.com/Genymobile/scrcpy (Apache-2.0, copyright its contributors)

The \`AudioProbe/ProbeRuntime.java\` runtime bootstrap is derived conceptually and in structure from PhoneBridge's \`ShellRuntime.java\` (Apache-2.0 OR MIT). This project retains attribution and references its source license. The rest of the probe is application-specific diagnostic code, not PhoneBridge audio streaming components.

Neither source project is affiliated with or endorses SIM AI Assistant. Verify current license texts in the above repositories before redistributing modified code.
