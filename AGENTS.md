# Agent rules for this fork

This repository is **public**. Never commit personal data, real unpublished scripts, user paths outside the repo, tokens, or private notes. Synthetic fixtures only.

## Build & test (must be green before you finish)

```sh
# Pure-logic core package (fast, no Xcode project needed)
cd Packages/FrameScriptCore && swift test

# App
xcodebuild -project FrameScript.xcodeproj -scheme FrameScript -destination 'platform=macOS' \
  -derivedDataPath /tmp/fsdd-$(basename "$PWD") build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project FrameScript.xcodeproj -scheme FrameScript -destination 'platform=macOS' \
  -derivedDataPath /tmp/fsdd-$(basename "$PWD") CODE_SIGNING_ALLOWED=NO -skip-testing:FrameScriptUITests
```

Use a derived-data path unique to your checkout (as above) so parallel agents do not collide.

## Layout and ownership

- `Packages/FrameScriptCore/` — UI-free Swift package (Foundation only, Swift 6 strict concurrency, macOS 14). Pure logic lives here, one subfolder per feature: `Sources/FrameScriptCore/<Feature>/`, tests in `Tests/FrameScriptCoreTests/<Feature>Tests.swift`, fixtures in `Tests/FrameScriptCoreTests/Fixtures/<Feature>/`. Public API must be `public` and `Sendable` where sensible. Use Swift Testing (`import Testing`, `@Test`, `#expect`).
- `FrameScript/` — the macOS app. Its folders are Xcode *file-system synchronized groups*: any `.swift` file you add under `FrameScript/` is compiled into the app target automatically. Do **not** put executables or `main.swift` there.
- New app features go in `FrameScript/Features/<Feature>/`. Extend shared types through new files (`AppState+<Feature>.swift`, `ExportService+<Feature>.swift`) instead of editing the big shared files, unless your task says you own them.
- Localization: never edit the base tables in `Core/Utilities/Localization.swift` unless your task owns them. Add `FrameScript/Core/Utilities/Localization+<Feature>.swift` with `extension L10n { static let <feature>Strings: [AppLanguage: [String: String]] = [...] }` providing `.english` and `.russian` (and `.spanish` once that case exists), and append it to `featureTables` in `Localization+Features.swift`.
- Stay inside the files your task lists. If you must touch something else, keep the change minimal and say so in your final report.

## Conventions

- Swift 6, strict concurrency, no force unwraps on data that can be missing, no new third-party dependencies.
- Every piece of pure logic gets unit tests. Tests must not need network, microphone, OBS, or T3.
- Commit on your branch with clear messages. Do not push. Do not merge.
- Final report: what you built, files touched, test counts (actual numbers from the run), and anything left undone or uncertain. Do not claim something works unless you ran it.

## Running the app (the user works on this Mac at the same time)

Never bring FrameScript to the foreground or steal focus.

- Launch in the background without activating: `open -g -n /path/to/FrameScript.app` (never plain `open`, never `activate`, never `osascript … tell application … to activate`).
- Do NOT send synthetic keyboard/mouse events (no `System Events` keystrokes/clicks, no cliclick). Drive behaviour through unit/integration tests or DEBUG launch arguments/hooks instead.
- Screenshots: capture only the FrameScript window, even if it is behind other apps:
  `WID=$(swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]; for w in l where (w["kCGWindowOwnerName"] as? String) == "FrameScript" && (w["kCGWindowLayer"] as? Int) == 0 { print(w["kCGWindowNumber"]!); break }')` then `screencapture -x -o -l "$WID" /tmp/<name>.png`.
- Always quit the instance you launched when done (`pkill -f "<derived-data path>/.*FrameScript.app"`), never other running instances.
