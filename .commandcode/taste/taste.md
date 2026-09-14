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

## Cross-Platform & Delivery
- Targets all platforms equally — macOS, Android, iOS, and Web — and expects each platform's limitations to be respected in recommendations. Confidence: 0.85
- Prefers a conservative, evidence-based approach to adopting new technology: keep the existing solution as a baseline and adopt new libraries or engines only where testing demonstrates a clear benefit, rather than wholesale migration. Confidence: 0.9
- Expects a formal verification pipeline before work is considered done: flutter analyze, flutter test, native debug build, and web release build all passing. Confidence: 0.9
- Wants physical device verification (real macOS and real Android hardware) for playback behavior — simulators and emulators are insufficient for final sign-off. Confidence: 0.85
- Respects and preserves existing legal/policy boundaries (e.g., legal-only catalogue behavior) without adding backends or bypassing source policies. Confidence: 0.9
- Separates planning from implementation as two distinct phases — produces a detailed plan, gets explicit approval ("PLEASE IMPLEMENT THIS PLAN"), and only then writes code. Confidence: 0.95
- Uses a monorepo structure with Melos for managing multiple Dart/Flutter packages alongside Rust code, with path dependencies and `pubspec_overrides.yaml` for local development. Confidence: 0.9
- Manages Flutter versions via FVM (Flutter Version Management) to pin and reproduce builds across machines. Confidence: 0.85
- Expects re-audit of plans when context changes (e.g., after a plan is already implemented or a new package is integrated) — does not want stale assumptions carried forward. Confidence: 0.85
- Follows a strict git branching convention: `{type}/{feature-name}` in kebab-case (types: feat/, fix/, refactor/, docs/, chore/), with all feature work on a branch and no commits unless explicitly requested by the user. Confidence: 0.95
- Opens a PR against `main` only when the feature is complete and tested, and only after the user asks — never auto-pushes or auto-creates PRs without request. Confidence: 0.9
- Skips branching for read-only work (questions, code review, exploration) or when continuing on an existing feature branch — only branches for new feature work. Confidence: 0.85
- Defines specific, measurable acceptance thresholds for performance work (e.g., under 1% dropped frames, under 100ms A/V offset, minimum 15% repeatable improvement) before considering a change validated. Confidence: 0.9
