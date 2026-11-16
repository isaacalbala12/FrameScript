# Escaleta Markdown round trip: known limits

FrameScript exports an imported escaleta back to Markdown so the document can
travel to another tool and return. The parser and exporter preserve headings,
scene text, cues, tables, publishing fields, source lines and pending
verification items.

## Research metadata that stays only in the `.fscr` file

The following fields live in `FrameScriptDocument` (and are therefore preserved
by saving and reopening a `.fscr`) but are **not** written to the exported
Markdown:

- claim status, `needsVerification`, `personalExperience`, the resolution note
  and the claim's source ids;
- source kind, reliability and date;
- claims that have no open research task.

The reason is structural: the structural round-trip metadata
(`__framescript_escaleta_metadata__:`) is stored inside `FrameProject.topic` in
the `.fscr` document. The Markdown exporter does not emit that metadata line, so
adding fields to it cannot carry them through a Markdown file. On re-import the
mapper rebuilds the claims as `probable` + needs verification and rebuilds
sources from the human-readable lines.

The app therefore treats the exported Markdown as a human/AI interchange format,
not as a lossless research backup. Use `.fscr` (or an export format that keeps
the project model) when claim/source classification must survive the round trip.
A future format revision can add a hidden Markdown carrier for this metadata;
until then this limitation is intentional and documented here.
