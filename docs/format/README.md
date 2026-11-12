# The `.fscr` project format (version 4)

FrameScript saves one project as one `.fscr` file: a plain UTF-8 JSON document, no
container, no compression, no sidecar files. This directory contains everything a
second implementation needs to read and write it:

| File | Purpose |
| --- | --- |
| [`fscr-v4.schema.json`](fscr-v4.schema.json) | JSON Schema (draft 2020-12), one `$defs` entry per type |
| `README.md` | This guide: encoding rules, migrations, anchors, snapshots, examples |

The Swift reference implementation lives in
[`Packages/FrameScriptCore/Sources/FrameScriptCore/Document/`](../../Packages/FrameScriptCore/Sources/FrameScriptCore/Document/):

- `FrameScriptDocument.swift` — the Codable types that define the format.
- `FrameScriptDocumentCodec.swift` — date/JSON strategies, atomic writes.
- `FrameScriptDocumentMigration.swift` — v1→v4 migration and validation.
- `History/SnapshotCodec.swift` — the compressed history payload.

The tests in
[`FormatSchemaTests.swift`](../../Packages/FrameScriptCore/Tests/FrameScriptCoreTests/FormatSchemaTests.swift)
validate the schema against the encoder, validate the examples in this file, and fail
when a stored Swift property is missing from the schema.

---

## 1. File overview

```
.fscr
└── object
    ├── fileVersion : integer (4)
    └── project     : Project
        ├── id, title, createdAt, updatedAt
        ├── scenes[]           ← the script
        ├── assets[]           ← files referenced by the project
        ├── sources[], claims[], comparisonTables[], glossary[]
        ├── clips[]            ← short-form derivatives
        ├── checklistTasks[], exportPresets[]
        ├── publishingPacks{}  ← language code → PublishingPack
        ├── publishedVideos{}  ← language code → PublishedVideoComparison
        ├── versionHistory[]   ← compressed snapshots
        ├── aiThreadMap{}
        └── unparsedSections[]
```

- **Extension:** `.fscr`. The legacy extension `.framescript` is accepted by the app.
- **UTI:** `com.drashko.framescript.project`, which conforms to `public.json`.
- **Encoding:** UTF-8 JSON, one top-level object. The Swift writer uses
  `JSONEncoder.outputFormatting = [.sortedKeys]`, so members are sorted
  alphabetically, but member order is **not** significant and readers must not rely
  on it.
- **Size:** no limit in the format. The app's history payloads enforce a 64 MiB
  decompression cap per snapshot (see §5).

Every project-level collection is always present, even when empty. Members that are
optional in the Swift type are omitted when `nil`; the writer never emits JSON
`null`.

---

## 2. JSON encoding rules

| Swift type | JSON | Notes |
| --- | --- | --- |
| `String` | string | Any Unicode. No normalization and no trimming: text is stored as typed. |
| `Int`, `Int64` | integer | Signed 64-bit range. `fileSize` is `Int64`; everything else is `Int`. |
| `Double`, `TimeInterval` | number | `TimeInterval` is seconds as a `Double`. An integral value is written without a decimal part (`42`, not `42.0`), so **do not** use integer-vs-float JSON typing to distinguish fields. |
| `Bool` | boolean | |
| `UUID` | string, `format: uuid` | Canonical hyphenated form. Foundation writes **uppercase** (`CCCCCCCC-...`); readers must accept any case. |
| `Date` | string, `format: date-time` | ISO-8601 instant in UTC with six fractional digits, e.g. `2024-01-01T10:00:00.000000Z`. Readers must also accept second precision (`...:00Z`), millisecond precision (`...:00.000Z`), and explicit offsets (`...+02:00`). |
| `Data` | string, base64 | Standard alphabet with padding; empty data is `""`. Used by `bookmarkData` and `compressedPayload`. |
| `[T]` | array | Order is significant unless a property description says otherwise. |
| `[String: T]` | object | String keys only. Used for language-keyed maps. |
| `T?` | member omitted | Absent means `nil`. `null` is never written; a reader should treat it as absent. |

Two more rules:

- **No NaN or infinity.** Foundation's `JSONEncoder` throws on non-finite doubles, so
  a valid file cannot contain them. Cross-platform writers must reject them too.
- **Dates are instants, not local times.** The writer converts to UTC; the `Z`
  suffix is what it emits. Offsets other than `Z` should still be parsed.

### Unknown members

Every object in the schema sets `additionalProperties: true`. A reader must ignore
members it does not know. This is what lets a v4 file carry data from a later build
without breaking older readers.

The Swift reader ignores unknown members **and drops them when it saves**, so a
read-modify-write cycle through the macOS app is not lossless for data added by a
newer writer. A cross-platform implementation that wants round-trip fidelity should
retain unknown members and write them back. Either way, an unknown member is never
an error.

---

## 3. Versioning and migration

`fileVersion` is the schema version of the document itself.

| Version | Meaning |
| --- | --- |
| 1 | First public format. B-roll and editing notes were linked to text segments only (`linkedSegmentID`), with no text anchor. |
| 2 | Added `textAnchor`. A v2 file may still contain segment-only links. |
| 3 | Last pre-v4 layout. Anchors were repaired on every load. |
| 4 | **Current.** Adds per-project production, publishing, assets, research, clips, version history, language variants and published-video comparison data. Every new member is optional or has a decode default, so v1–v3 files open unchanged. |

### Rules

- A reader accepts `1 <= fileVersion <= 4` and migrates in memory.
- A writer always writes `4`. `FrameScriptDocumentCodec.encode` overwrites whatever
  the in-memory value was.
- `fileVersion > 4` is an **error**, never a best-effort read. Report it as
  "saved by a newer version of FrameScript" and stop.
- `fileVersion < 1` is also an error.
- A v4 document is validated but **not modified** on read.

### What the migration does

| From | Steps |
| --- | --- |
| 1 | Derive anchors from `linkedSegmentID` (segment text is matched against `scriptText`), repair anchors, normalize cross-references. |
| 2 | Same as v1: legacy segment links are still possible in v2 files. |
| 3 | Repair anchors, normalize cross-references. |
| 4 | Validation only. |

- **Legacy link → anchor.** For each b-roll/editing item with no anchor and a
  `linkedSegmentID` that resolves to a segment of the same scene, the segment text
  is located in `scriptText` and turned into an anchor. If it cannot be located, both
  the link and the anchor are cleared.
- **Anchor repair** follows §4. Unrepairable anchors are removed and their
  `linkedSegmentID` is cleared.
- **Cross-reference normalization** drops asset links (`linkedSceneIDs`,
  `linkedBRollItemIDs`, `linkedTakeIDs`), claim links (`sourceIDs`, `sceneIDs`) and
  clip links (`sourceSceneIDs`) that do not resolve, removes duplicates, and clears
  `anchorSceneID` plus `anchor` when the scene is missing.
- **Validation.** Scene IDs must be unique project-wide, and every b-roll and
  editing anchor must satisfy `0 <= startUTF16` and `0 <= lengthUTF16` and
  `startUTF16 + lengthUTF16 <= utf16Length(scriptText)`.

### When to introduce version 5

Only for a change an old reader cannot survive: a renamed or removed member, a
changed meaning, a new required member, or a new enum case that old readers must
understand. Adding an optional member does **not** need a version bump.

### A caveat about enum cases

The Swift reader decodes enums strictly: an unknown raw value fails the whole file.
Adding a case to `SectionType`, `BRollStatus`, etc. inside v4 would therefore make
files unreadable by older FrameScript builds. If a new case is unavoidable, bump
`fileVersion`; new readers should additionally map unknown values to a sensible
default instead of failing.

---

## 4. Text anchors (UTF-16)

`TextAnchor` points at a selection inside a scene's script:

```json
{
  "startUTF16": 6,
  "lengthUTF16": 6,
  "selectedText": "target",
  "prefixContext": "alpha ",
  "suffixContext": " omega"
}
```

- `startUTF16` and `lengthUTF16` are offsets into **`Scene.scriptText`**, counted in
  **UTF-16 code units** — the unit used by `NSString`/`NSRange`, JavaScript
  `String.prototype.length`, Java `char` indices and C# `string` indices. They are
  not Unicode scalar or grapheme counts. `"🎬"` is one character but two UTF-16
  units; on a non-BMP character a naive code-point implementation will drift.
- `selectedText` must equal the substring at `[startUTF16, startUTF16+lengthUTF16)`.
- `prefixContext` / `suffixContext` hold up to **48 UTF-16 code units** immediately
  before/after the selection, snapped outward to grapheme-cluster boundaries. They
  are empty at the start/end of the text.
- Anchors are used by `BRollItem.textAnchor`, `EditingItem.textAnchor` and
  `ShortClip.anchor` (the latter is relative to `anchorSceneID`'s script). The
  decoder applies defaults (`0` / `""`) to missing anchor members; v4 validation
  then rejects out-of-range b-roll/editing anchors.

### Repair algorithm

When a script is edited, an anchor may no longer match. The reference algorithm
(`TextAnchorRepair`) is:

1. If `selectedText` still occurs exactly at the stored range, keep that range and
   recompute both context strings.
2. Otherwise, find every occurrence of `selectedText` (case-sensitive, no Unicode
   normalization). Give up if there are 512 or more.
3. Keep the occurrences whose immediately preceding text equals `prefixContext`
   **or** whose immediately following text equals `suffixContext`. If exactly one
   remains, use it.
4. If `selectedText` occurs nowhere, build candidate ranges from every position
   where `prefixContext` ends to every position where `suffixContext` starts. If
   exactly one candidate exists, use it.
5. Otherwise the anchor is unrepairable: drop it (and the link that depends on it).

After a successful repair, rewrite all five members from the located range; do not
keep stale context.

**v4 reads do not repair.** Anchors in a v4 file may be stale after external edits;
repair them when the user edits the script, not when the file is loaded.

### Practical guidance for other languages

- Slice with UTF-16 code units (JS: `Array.from` is wrong, use `String.prototype.slice`;
  Rust: `str::encode_utf16` offsets; Python: `str.encode('utf-16-le')` indices).
- Never normalize (`NFC`/`NFD`), trim or case-fold the script when computing offsets.
- Treat a repaired anchor as new data: its context strings change even when the
  offsets do not.

---

## 5. Version history payloads

`Project.versionHistory[]` stores earlier states of the project. Each
`VersionSnapshot.compressedPayload` is **base64 of a small binary envelope**, not
plain JSON:

```
offset  size  field
0       4     magic        "FSSC" (0x46 0x53 0x53 0x43)
4       1     version      1
5       1     flags        0 = zlib
6       2     reserved     must be 0
8       8     rawLength    uncompressed byte count, little endian uint64
16      8     zipLength    compressed byte count, little endian uint64
24      4     crc32        CRC-32 (IEEE 802.3, poly 0xEDB88320) of the uncompressed bytes, little endian uint32
28      N     payload      zlib stream (RFC 1950), N = zipLength
```

- The uncompressed bytes are the UTF-8 JSON of a complete document in **this same
  format** (a `FrameScriptDocument`, normally with `fileVersion: 4`), captured when
  the snapshot was taken.
- To read: base64-decode, check the magic/version/flags/reserved bytes, check that
  `zipLength` equals the remaining byte count, inflate, check the length against
  `rawLength`, then verify the CRC-32 before parsing JSON.
- Enforce a maximum `rawLength` before allocating. The reference limit is 64 MiB
  (`SnapshotCodec.defaultMaximumUncompressedSize`); scripts are far smaller.
- Version 1 with flags 0 is the only combination in use. Reject anything else
  instead of guessing.
- A reader that only needs the current project may ignore `versionHistory`
  entirely. A reader that offers restore must also accept that a snapshot payload is
  an older document and may need migration.

The example in §9 contains a real payload: it decompresses to the minimal document
shown above it.

---

## 6. Languages

- `Project.primaryLanguage` is the language the script was written in (`"es"` in
  the examples). The decoder defaults it to `"es"` for legacy files.
- Language codes are BCP-47-ish short strings (`es`, `en`, `pt-BR`). The format does
  not enumerate them; preserve the exact string, including case.
- There are two shapes:
  - **`Scene.languageVariants[]`** — one entry per translated language. Each has
    `languageCode`, translated `text`, `sourceHash`, its own `takes`, and
    `estimatedDuration` / `actualDuration`. B-roll and editing notes are **not**
    duplicated: they live on the original scene and stay anchored to the original
    `scriptText`.
  - **Language-keyed objects** — `Project.publishingPacks`, `Project.publishedVideos`
    and `Project.learnedWordsPerMinuteByLanguage` are JSON objects whose keys are
    language codes.
- `Take.languageCode` and `ShortClip.languageCode` select the language of that take
  or clip. Empty means "the scene's original language".
- `PublishingPack` holds titles, description, tags, hashtags, pinned comment,
  community post, chapter overrides and thumbnail variants for one language.

### Stale translations

`sourceHash` is the FNV-1a 64-bit hash of the original `scriptText` at the time the
translation (or clip) was produced. Recompute it from the current text; if it
differs, the translation is stale. Do not "fix" the hash: it is a fingerprint, and
the user decides whether to re-translate.

---

## 7. Identifiers, hashes and cross-references

- Every `id` is a UUID string. Foundation writes uppercase; comparison must be
  case-insensitive.
- **Scene IDs must be unique within a project.** The reader rejects duplicates.
  Other IDs are expected to be unique but are not validated.
- References are plain UUID strings:
  `TextSegment.sceneID` → the containing `Scene.id`; `AIComment.sceneID/segmentID`;
  `BRollItem.linkedSegmentID`; `EditingItem.linkedSegmentID`;
  `ProjectAsset.linkedSceneIDs/linkedBRollItemIDs/linkedTakeIDs`;
  `Claim.sourceIDs/sceneIDs`; `ChapterOverride.sceneID`; `ChecklistTask.sceneID`;
  `ThumbnailVariant.assetID`; `ShortClip.sourceSceneIDs/anchorSceneID`;
  `PublishedVideoComparison.SceneResult.sceneID`.
- Migration cleans dangling references from v1–v3 files. A v4 file is trusted:
  readers should tolerate a missing target instead of rewriting the file.
- `sceneSourceHashes[].hash` and `ShortClip.sourceHash` are FNV-1a 64-bit hashes.
  `Take.sceneTextHash` uses the same function. The hash is computed over the UTF-8
  bytes of the text, then rendered as **lowercase hexadecimal without zero
  padding** (so the empty string hashes to `cbf29ce484222325`). Parameters:

  ```
  offset basis = 0xcbf29ce484222325
  prime        = 0x00000100000001b3
  for each byte: value ^= byte; value = (value * prime) mod 2^64
  ```

- `Scene.order` defines scene order; do not trust array order. The same applies to
  `TextSegment.order` within a scene.

---

## 8. Changing the format safely

1. **Add, don't rename.** A new member is optional, has a decode default, is absent
   from the schema's `required` list, and is documented in the schema and here.
2. **Never change a key name or an enum raw value.** `EditingItem` shows the
   supported pattern for a rename: writers emit the new key (`description`) and the
   reader also accepts the old one (`cutStyle`, marked `deprecated` in the schema).
3. **Only bump `fileVersion` for incompatible changes.** Add a migration branch for
   the old versions and update `FrameScriptFormat.currentFileVersion`; never reuse a
   version number.
4. **Keep `additionalProperties: true`.** The schema is deliberately open so that
   newer writers do not break older readers.
5. **Prefer string-keyed maps or arrays of objects.** Swift encodes
   `[String: T]` as a JSON object, but a dictionary with non-string keys (for
   example `[UUID: T]`) becomes a flat array of alternating keys and values, which
   is unreadable in other languages. Use `[SomeObject]` instead.
6. **Use `Int` for counters and sizes, `Double` for time.** A JSON reader cannot
   reliably tell `42` from `42.0`.
7. **Do not add `null`.** `nil` is encoded by omitting the member.
8. **Update the artifacts together.** A format change touches the Swift types, this
   guide, `fscr-v4.schema.json`, and the tests. Run:

   ```sh
   cd Packages/FrameScriptCore && swift test --filter FormatSchema
   ```

9. **Test with the full builder.** `DocumentFormatTests.fullDocument()` populates
   every optional property; the schema tests compare its encoded keys with the
   schema in both directions. If you add a property and do not add it there, the
   schema test cannot see it — so update the builder too.

---

## 9. Examples

### Minimal valid file

Every member that is always written must be present; every optional member is
omitted. This file opens as an empty project.

<!-- example:minimal -->

```json
{
  "fileVersion": 4,
  "project": {
    "id": "7ae09594-668f-437c-9f7e-bb7b07eadf08",
    "title": "Minimal project",
    "createdAt": "2026-01-01T09:00:00.000000Z",
    "updatedAt": "2026-01-01T09:00:00.000000Z",
    "exportPresets": [],
    "scenes": [],
    "primaryLanguage": "es",
    "topic": "",
    "videoType": "",
    "productionStatus": "idea",
    "learnedWordsPerMinuteByLanguage": {},
    "assets": [],
    "publishingPacks": {},
    "checklistTasks": [],
    "sources": [],
    "claims": [],
    "comparisonTables": [],
    "glossary": [],
    "clips": [],
    "versionHistory": [],
    "aiThreadMap": {
      "t3ProjectID": "",
      "threadIDsByProviderModel": {}
    },
    "unparsedSections": [],
    "publishedVideos": {}
  }
}
```

### Fuller example

One scene with a segment, a review comment, a b-roll note and an editing note (both
anchored to `"target"`), a take, an English variant, plus project-level assets,
publishing data, research, a short clip and one history snapshot. The snapshot
payload decompresses to the minimal document above.

<!-- example:full -->

```json
{
  "fileVersion": 4,
  "project": {
    "id": "9a5d3a2e-6c1b-4a55-9a2f-8a0e5c1d7b11",
    "title": "Revisión de sim racing",
    "createdAt": "2026-02-10T08:30:00.000000Z",
    "updatedAt": "2026-02-11T17:05:12.123456Z",
    "templateID": "1f0a8e3c-9d44-4c2b-8f4e-2b6d7a9c5e01",
    "settingsOverride": {
      "wordsPerMinute": 160,
      "defaultSplitMode": "sentence"
    },
    "exportPresets": [
      {
        "id": "5b2c7d1e-3f4a-4b6c-8d9e-0f1a2b3c4d5e",
        "name": "YouTube chapters",
        "format": "CSV"
      }
    ],
    "scenes": [
      {
        "id": "22222222-2222-4222-8222-222222222222",
        "order": 0,
        "sectionType": "Hook",
        "title": "Cold open",
        "scriptText": "alpha target omega",
        "notes": "Grab attention in the first two seconds.",
        "estimatedDuration": 4.5,
        "textSegments": [
          {
            "id": "33333333-3333-4333-8333-333333333333",
            "sceneID": "22222222-2222-4222-8222-222222222222",
            "order": 0,
            "sourceText": "alpha target omega",
            "segmentType": "scene",
            "timingEstimate": 4.5
          }
        ],
        "aiComments": [
          {
            "id": "12121212-1212-4212-8212-121212121212",
            "sceneID": "22222222-2222-4222-8222-222222222222",
            "segmentID": "33333333-3333-4333-8333-333333333333",
            "type": "pacing",
            "severity": "suggestion",
            "message": "The hook can be shorter.",
            "suggestion": "Cut the second sentence.",
            "status": "dismissed"
          }
        ],
        "bRollItems": [
          {
            "id": "44444444-4444-4444-8444-444444444444",
            "textAnchor": {
              "startUTF16": 6,
              "lengthUTF16": 6,
              "selectedText": "target",
              "prefixContext": "alpha ",
              "suffixContext": " omega"
            },
            "linkedSegmentID": "33333333-3333-4333-8333-333333333333",
            "templateType": "wide",
            "sourceType": "Screen recording",
            "descriptionText": "Show the lap timer.",
            "mood": "tense",
            "framing": "close",
            "motion": "static",
            "duration": 2.5,
            "notes": "Record at 60 fps.",
            "status": "Done"
          }
        ],
        "editingItems": [
          {
            "id": "55555555-5555-4555-8555-555555555555",
            "textAnchor": {
              "startUTF16": 6,
              "lengthUTF16": 6,
              "selectedText": "target",
              "prefixContext": "alpha ",
              "suffixContext": " omega"
            },
            "linkedSegmentID": "33333333-3333-4333-8333-333333333333",
            "templateType": "punch-in",
            "description": "hard cut",
            "transition": "fade",
            "subtitleStyle": "bold",
            "emphasis": "high",
            "zoom": "110%",
            "sfx": "whoosh",
            "musicCue": "drop",
            "graphics": "lower third",
            "notes": "Keep the beat on the cut.",
            "status": "done"
          }
        ],
        "targetDuration": 5,
        "takes": [
          {
            "id": "66666666-6666-4666-8666-666666666666",
            "number": 3,
            "startedAt": "2026-02-11T16:00:00.000000Z",
            "duration": 4.75,
            "filePath": "/Users/editor/Movies/take-3.mov",
            "bookmarkData": "AQID",
            "rating": "good",
            "note": "Best delivery.",
            "languageCode": "es",
            "readText": "alpha target omega",
            "sceneTextHash": "f0e1d2c3b4a59687"
          }
        ],
        "languageVariants": [
          {
            "languageCode": "en",
            "text": "alpha target omega translated",
            "sourceHash": "f0e1d2c3b4a59687",
            "takes": [],
            "estimatedDuration": 4.25,
            "actualDuration": 0
          }
        ],
        "obsSceneName": "Camera"
      }
    ],
    "primaryLanguage": "es",
    "topic": "sim racing",
    "videoType": "review",
    "productionStatus": "edited",
    "targetDate": "2026-02-20T18:00:00.000000Z",
    "publishDate": "2026-02-21T16:00:00.000000Z",
    "targetDuration": 720,
    "learnedWordsPerMinuteByLanguage": {
      "es": 152.5,
      "en": 161
    },
    "assets": [
      {
        "id": "77777777-7777-4777-8777-777777777777",
        "path": "/Users/editor/Movies/thumb.png",
        "bookmarkData": "BAUG",
        "kind": "thumbnail",
        "tags": ["thumbnail", "cover"],
        "linkedSceneIDs": ["22222222-2222-4222-8222-222222222222"],
        "linkedBRollItemIDs": ["44444444-4444-4444-8444-444444444444"],
        "linkedTakeIDs": ["66666666-6666-4666-8666-666666666666"],
        "isCopiedIntoProject": true,
        "duration": 0,
        "fileSize": 204800,
        "modifiedAt": "2026-02-11T12:00:00.000000Z",
        "isLastKnownMissing": false
      }
    ],
    "publishingPacks": {
      "es": {
        "titleCandidates": ["Probando el circuito", "Mi vuelta perfecta"],
        "chosenTitle": "Mi vuelta perfecta",
        "description": "Una vuelta comentada.",
        "tags": ["simracing"],
        "hashtags": ["#simracing"],
        "pinnedComment": "¿Qué circuito debería probar?",
        "communityPost": "",
        "chapterOverrides": [
          {
            "id": "88888888-8888-4888-8888-888888888888",
            "sceneID": "22222222-2222-4222-8222-222222222222",
            "title": "Cold open",
            "startSeconds": 0,
            "isExcluded": false
          }
        ],
        "thumbnailVariants": [
          {
            "id": "99999999-9999-4999-8999-999999999999",
            "assetID": "77777777-7777-4777-8777-777777777777",
            "pairedTitle": "Mi vuelta perfecta",
            "isChosen": true
          }
        ],
        "thumbnailConceptNotes": "Face plus lap timer."
      }
    },
    "checklistTasks": [
      {
        "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "text": "Record the cold open",
        "kind": "record",
        "isDone": true,
        "sceneID": "22222222-2222-4222-8222-222222222222"
      }
    ],
    "rhythmThresholdsOverride": {
      "longSentenceWordLimit": 28,
      "uncoveredSecondsLimit": 5,
      "sceneLengthRatioLimit": 1.8,
      "hookSecondsLimit": 15
    },
    "sources": [
      {
        "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "title": "Lap record",
        "url": "https://example.com/lap-record",
        "note": "Official timing."
      }
    ],
    "claims": [
      {
        "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        "text": "The record is 1:42.3.",
        "status": "confirmed",
        "sourceIDs": ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"],
        "sceneIDs": ["22222222-2222-4222-8222-222222222222"]
      }
    ],
    "comparisonTables": [
      {
        "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        "title": "Tyres",
        "header": ["Compound", "Lap time"],
        "rows": [["Soft", "1:42.3"], ["Hard", "1:43.9"]]
      }
    ],
    "glossary": [
      {
        "id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        "source": "apex",
        "target": "apex",
        "isProtected": true
      }
    ],
    "clips": [
      {
        "id": "ffffffff-ffff-4fff-8fff-ffffffffffff",
        "title": "The perfect lap",
        "sourceSceneIDs": ["22222222-2222-4222-8222-222222222222"],
        "anchorSceneID": "22222222-2222-4222-8222-222222222222",
        "anchor": {
          "startUTF16": 6,
          "lengthUTF16": 6,
          "selectedText": "target",
          "prefixContext": "alpha ",
          "suffixContext": " omega"
        },
        "hook": "One lap, no mistakes.",
        "adaptedText": "One lap, no mistakes.",
        "targetSeconds": 30,
        "format": "reel",
        "onScreenText": "1:42.3",
        "description": "Short version of the review.",
        "hashtags": ["#simracing"],
        "sourceHash": "f0e1d2c3b4a59687",
        "languageCode": "es",
        "sceneSourceHashes": [
          {
            "sceneID": "22222222-2222-4222-8222-222222222222",
            "hash": "f0e1d2c3b4a59687"
          }
        ],
        "status": "ready"
      }
    ],
    "versionHistory": [
      {
        "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
        "createdAt": "2026-02-11T17:00:00.000000Z",
        "name": "Before the rewrite",
        "isAutomatic": false,
        "label": "manual",
        "compressedPayload": "RlNTQwEAAABBAgAAAAAAAFQBAAAAAAAAh5Y1vY1Sy26DMBD8lcpnqNwkDYFboxwaqZGQglKpVQ/GXogbB1t+REUR/94FQnMt8sE7Azuzs1xJJRUcwDqpG5ItImKs/gbuSXYlTBZHC0zsmOlLP89HbrshGSER8QO73bh1i8xFCrA7LUDhy10XEeYceEeyz6+I8CPwk5LOF8ydJkwxef67SzNd9dkwK51uClYqmFCU8iBe0BiZ0dkypk94CppmlOJ5pMPzga7gx2jrcwt39Vpp55htx0oK7JEwoOlzuoiXy1UVL+YJj9Mqgbgsk5ImOFZFV9hMAbMNiHdthctxPNkED+v2jTV1YDX0k/aRyTN2v4MEXQ9JisA9Brv3zAf0gtLAeiaUmMURxAEB7W5dRlA2dc746QY6Ds0UgdPB8qnw0qteCR2huHqY1oaMNpKPCwoNJulA7GGwcfs0GPHPKC/jf/GKe9NTev2addGaXpx03S8="
      }
    ],
    "aiThreadMap": {
      "t3ProjectID": "t3-project",
      "threadIDsByProviderModel": {
        "openai/gpt-4.1-mini": "thread-1"
      }
    },
    "unparsedSections": [
      {
        "heading": "Leftovers",
        "body": "Do not lose this."
      }
    ],
    "publishedVideos": {}
  }
}
```

---

## 10. Schema and tests

`fscr-v4.schema.json` is a draft 2020-12 schema with one `$defs` entry per Swift
type, exact enum raw values, `format: "uuid"` / `"date-time"` annotations, and
`additionalProperties: true` on every object (map members use a value schema; see
`learnedWordsPerMinuteByLanguage`, `publishingPacks`, `publishedVideos` and
`threadIDsByProviderModel`).

`required` lists exactly the member names the Swift encoder always writes. In
practice those are the non-optional stored properties; `EditingItem.cutStyle` is the
one case where the written member has a different name (`description`), kept for
v1–v3 compatibility. Optional properties are never required. That is why the minimal
example above has to spell out every empty array and both language maps, and why
`ProjectSettingsOverride` / `RhythmThresholds` may be `{}`.

The test suite enforces this contract:

- `Schema is self-consistent` — refs resolve, defs are reachable, every member has a
  description, every object allows unknown members.
- `The maximal document validates` — the full builder from `DocumentTests` is encoded
  and validated.
- `A sparse document encodes exactly the required keys` — with every optional unset,
  the encoder's keys equal `required` for every type.
- `Migrated v1, v2 and v3 fixtures produce schema-valid v4 documents`.
- `Encoded keys and schema properties agree in both directions` — a key the encoder
  writes must be declared, and a declared member must be written by the full
  builder (deprecated read-only aliases excepted).
- Both examples in this file are parsed from the Markdown, validated against the
  schema and decoded by the reference implementation.

Run them with:

```sh
cd Packages/FrameScriptCore && swift test --filter FormatSchema
```

The tests read this directory from the repository, so run them from a full
checkout, not from an extracted copy of the Swift package.
