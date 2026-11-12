# Changelog

## [Unreleased]

### Added

- Added script-editor markup styling for inline pauses (`/`, `//`, `[2s]`, `[pausa]`), emphasis (`*…*`, `**…**`) and bracket cues: delimiters stay visible but dim, emphasis renders italic/bold, and pauses/cues get subtle tinted tags.
- Added a local rhythm review (F26): wavy underlines in the editor, a "Ritmo" section in the review panel with click-to-select warnings, sidebar badge counts, per-video-type thresholds in Settings and a per-project override.
- Added per-language reading speeds (Spanish 150, English 160, Russian 140 wpm), configurable short/long pause durations, and clean "sin marcas" text and Markdown exports.
- Added `FrameScriptCore`, a UI-free Swift package linked into the app, with the `.fscr` document value types and codec.
- Added the v4 project schema for takes, learned speech rate, assets, per-language publishing packs, checklist tasks, sources and claims, comparison tables, language variants, short clips, version snapshots, T3 thread reuse, Markdown import leftovers, and published-video comparison.

### Changed

- Duration estimates for scenes, the sidebar and the project now run through `ScriptMarkup`: spoken words only (cues excluded) plus pause durations, using the per-language rate, the project's learned WPM when present, and the configured pause defaults.
- `.fscr` format v4 persists every Visuals and Editing field; readers migrate v1–v3 in memory and writers always emit v4. Files from a newer version fail with a clear error.
- Settings decoding falls back per field and per section instead of resetting every preference when a key is missing.
- Removed the App Sandbox entitlement; security-scoped bookmarks remain supported.

## [0.4.0] - 2026-07-13

### Added

- Added configurable keyboard shortcuts with recording, conflict reassignment, explicit unassignment, reserved-shortcut protection, persisted app-level bindings, immediate menu and visible-keycap updates, and layout-independent execution based on physical key positions.
- Added downloadable universal Apple Silicon and Intel DMG and ZIP builds with published SHA-256 checksums.

### Changed

- Replaced the built-in English and Russian demos with five-scene, anchor-first product showcases containing production plans, editing direction, and prepared local AI review notes; demo sessions now discard edits without prompts or autosave until explicitly saved as a project file.
- Made persisted Visuals and Editing relationships, grouping, selection, and marker navigation anchor-first; legacy segment-only links migrate when projects load, and invalid relationships appear as unlinked instead of pointing at stale script text.
- Simplified Settings and launch behavior, added a persisted inline-autocomplete control, and enabled AI review and inline autocomplete by default for new or reset settings while preserving existing saved preferences.
- Consolidated project exit and project-browser navigation into Back to Project List.

### Fixed

- Fixed v0.3.0 production-anchor repair, grouping, selection, and marker geometry so ordinary script edits keep unambiguous links aligned and stale or ambiguous relationships are cleared safely.
- Fixed v0.3.0 inline-autocomplete wrapping and editor geometry so ghost text respects TextKit layout, whitespace, paragraph spacing, and narrow-line boundaries.

### Removed

- Removed adjustable script-column width and line spacing in favor of a responsive 900 pt maximum text column and fixed typography.
- Removed the footer-shortcuts preference and footer shortcut bar; active shortcuts remain available in menus, controls, the command palette, and the shortcuts overlay.

## [0.3.0] - 2026-07-13

### Added

- Added inline AI autocomplete at the logical end of a script, with debounced one-sentence ghost text, Tab acceptance, Escape dismissal, IME awareness, stale-request cancellation, provider cooldowns, and localized availability details.
- Added Google AI Studio as a configurable AI provider for connection tests, AI review, rewrites, autocomplete, and production suggestions.
- Added controls to remove individual Recent Projects or clear the list without deleting project files.

### Changed

- Renamed user-facing production-footage terminology to Visuals (Видеоряд in Russian) across workspaces, AI output, exports, demo content, and current documentation while preserving compatible project-file keys.
- Changed saved-project autosave to coalesce rapid edits while editor text and live metrics commit immediately.
- Unified localized error and recovery presentation for project, settings, export, Keychain, Recent Project, and AI operations.
- Changed AI review to request and validate structured responses, preserve earlier results on failed retries, and follow the script language with the macOS language as fallback.
- Changed provider credential access so Settings uses saved-key metadata and a selected provider key is read from Keychain only for a connection test or AI request, then cached in memory until replaced or deleted.

### Fixed

- Fixed script text loss and stale-text replacement during mode, scene, window, desktop, and app-activity transitions; caret, selection, and scroll restoration are now kept per scene and editor window and clamped after shorter external updates.
- Fixed script caret, placeholder, and editor-column alignment, including insertion geometry in empty paragraphs.
- Fixed Script production-marker grouping and TextKit geometry so separate Visuals and Editing ranges retain their right-side lanes and individual hit targets.
- Fixed live word counts and scene, sidebar, and project duration estimates so they update on every committed edit, including untitled projects before save.
- Fixed the existing Script, Visuals, and Editing mode controls so their full visible surfaces are clickable and accessibility state is localized.
- Fixed Recent Project migration, bookmark validation, missing-file cleanup, unchanged-storage rewrites, and failure handling without discarding preserved legacy data.
- Fixed Keychain replacement and deletion error handling, including explicit replacement of legacy restricted entries.
- Fixed existing-provider AI review compatibility for token-truncated or harmlessly wrapped structured responses, including Groq JSON variants, while keeping parser diagnostics out of user-facing errors.
- Fixed autosave, sandbox export-folder bookmarks, settings persistence, and other critical file-operation failures that were previously silent or insufficiently recoverable.

## [0.2.0] - 2026-07-10

### Added

- Added segment-linked production planning across script, B-roll, and editing modes.
- Added `.fscr` project save/open support while keeping legacy `.framescript` files readable.
- Added Groq to the configurable AI provider options.
- Added the MIT License.

### Changed

- Reworked project state management around observable document models.
- Refined project creation, template customization, settings navigation, and production-note editing.
- Updated the app icon assets and current-demo documentation.

### Fixed

- Fixed project save/open behavior and Keychain service naming for saved AI provider credentials.

### Removed

- Removed voice-preview claims from the current release documentation; this entry does not claim removal of voice-related implementation.

## [0.1.0] - 2026-07-07

### Added

- Prepared the first public demo snapshot of the macOS SwiftUI app.
- Added scene-based script writing with B-roll, editing notes, duration estimates, AI review plumbing, voice preview, and export flows.
- Documented setup, project structure, current limitations, and security expectations.

### Changed

- None.

### Fixed

- None.

### Removed

- None.
