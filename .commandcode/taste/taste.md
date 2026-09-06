## Coding Style & Architecture
- Prefers vendoring external dependencies into the project (e.g., `packages/`) rather than relying on pub.dev packages, to maintain direct control and fix issues without waiting on upstream. Confidence: 0.9
- Prefers building native libraries from source over using opaque prebuilt binaries, even when the prebuilt option is available, for transparency and reproducibility. Confidence: 0.95
- Wants clear, user-facing error messages for stalled or failed operations (e.g., "source did not deliver enough video data") rather than silent failures or infinite spinners. Confidence: 0.85

## Workflow & Debugging
- Wants thorough analysis and evidence gathering before implementation — "analyze everything" — rather than jumping to a fix. Confidence: 0.9
- Insists on log-based diagnosis: checks native logs, Flutter logs, and player errors before deciding what to change. Confidence: 0.9
- Verifies fixes by running the app on the target platform (macOS) and observing live behavior. Confidence: 0.9
- Shares screenshots of errors and expects them to be treated as diagnostic evidence. Confidence: 0.8
- Prefers to review implementation plans in plan files with line-level comments and re-review cycles before any code is written — update plan in place, do not implement until approved. Confidence: 0.85

## Tooling
- Uses Flutter for desktop (macOS) app development with FFI for native interop. Confidence: 0.85
- Uses CocoaPods for macOS native dependency management within Flutter projects. Confidence: 0.7
- Installs native build dependencies via Homebrew when source compilation is needed. Confidence: 0.7
- Prefers local on-device persistence for watch history, playback progress, and saved lists (My List) over cloud sync. Confidence: 0.85
