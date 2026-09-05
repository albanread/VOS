# Slideshow Recital — agent skill

Turn a PDF (typically a computer manual) into a narrated slide video:
each page's margins are trimmed, portrait pages show half a page at a
time with a smooth scroll between halves, and the reference voice reads
a **summary** of the key points — never the page verbatim. A human
reviews the result in the timeline afterwards.

## Workflow

Run these against a running VoiceOverStudio (`osascript` or any
Apple Events client). Total flow for a 40-page manual is a few minutes.

1. **Import** — split, trim, and bake the silent stills movie:

   ```applescript
   tell application "VoiceOverStudio" to import slideshow from "/path/manual.pdf"
   ```

   Creates a clip with one empty narration stub per segment. Re-importing
   the same PDF reopens the existing clip.

2. **Dump** — get your eyes and source text:

   ```applescript
   tell application "VoiceOverStudio" to dump slideshow to "/tmp/manual-review"
   ```

   `manifest.json` lists every segment (number, page, crop, span,
   current narration). `seg-NNN.png` is exactly what the viewer will see;
   `seg-NNN.txt` is that page's full text. Review the PNG, not just the
   text — diagrams carry half the meaning in a manual.

3. **Write summaries** — for each segment, a spoken-style summary of the
   key points *visible in that viewport* (60–120 words is right for
   15–40 seconds). Keep a consistent voice across segments; use
   transitions so consecutive halves flow ("…and on the lower half of
   the page, …"). If a viewport has nothing worth saying, skip it:

   ```applescript
   tell application "VoiceOverStudio" to narrate segment number 3 script "..."
   tell application "VoiceOverStudio" to skip segment number 7
   ```

   Divider pages, blank half-pages, and pure-decoration crops are skips.

4. **Generate** — synthesize with the reference voice and re-bake with
   measured durations:

   ```applescript
   tell application "VoiceOverStudio" to initialize engines
   tell application "VoiceOverStudio" to generate missing
   ```

   `generate missing` writes only takes that are absent or stale (generated
   from different text) — on a 70-segment document it skips everything that
   is already current. `generate all` replaces every take; use it only when
   the voice itself changed. Generation re-times segments automatically and
   the movie re-bakes once at the end; `bake slideshow` re-bakes on demand.

5. **Verify and hand off**:

   ```applescript
   tell application "VoiceOverStudio" to slideshow info
   tell application "VoiceOverStudio" to export video to "~/Desktop/manual-recital.mov"
   ```

   The human then opens the clip's timeline in the app to review the
   transcript, reword any summary, and regenerate individual segments.

## Segment rules

- Segments number 1…N in reading order, stable across skips: upper half
  of a page first, then lower. Wide pages are a single segment.
- Skipped segments keep their stub (unanchored) so `unskip segment number N`
  restores them instantly.
- Timing is voice-driven: measured take when generated, text estimate
  until then, minimum 3s dwell when a stub is still empty. Narration
  starts 0.3s after the pan lands; 0.8s eased scroll joins the halves of
  a page.
- Anchor positions are computed, never hand-placed — edit the summary
  text, not the timeline.
