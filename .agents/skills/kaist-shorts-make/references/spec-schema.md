# spec.json schema

Read when writing or fixing spec.json fields. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

Paths are relative to the spec folder or the project folder (the one that contains `재료`); absolute paths also work. Plain JSON, UTF-8, no comments.

```json
{
  "output": "결과/261118-딸기/shorts.mp4",
  "title": [{"text": "20초 안에 읽어라", "color": "white"}, {"text": "딸기 잰말놀이", "color": "teal"}],
  "bottom_text": "↓ 풀영상은 KAIST 채널",
  "segments": [
    {"type": "video", "src": "재료/a.mp4", "in": 10.0, "out": 14.5},
    {"type": "image", "src": "재료/b.png", "duration": 3, "push_in": 0.08, "transition": "fade", "transition_duration": 0.3}
  ],
  "audio": {"mode": "original"},
  "captions": [{"start": 0.5, "end": 2.0, "text": "화면 안 자막"}],
  "sfx": [{"file": "재료/pop.wav", "at": 2.0, "volume_db": -14}],
  "loudness": {"target": -19, "true_peak": -1.5}
}
```

| Field | Meaning |
|---|---|
| `title` | exactly 2 lines. `color`: `white`, `teal`, or `#RRGGBB`. Optional `spacing` (letter spacing in px, default -5.6) |
| `bottom_text` | line under the video area; leading `↓` draws the arrow picture |
| `segments[]` | played in order. `video`: `src`, `in`, `out` (seconds), optional `volume` (default 1), optional `"fit": "width"` (fit the whole picture into the area width with black bars above and below instead of cropping the center; use when burned-in subtitles in the source would be cut off). `image`: `src`, `duration` (seconds), optional `push_in` (slow zoom; default 0 = the picture stays still; 0.08 = 8% larger at the end; set it only on a piece with something to emphasize), optional `crop` (`{"x":0.1,"y":0.1,"w":0.8,"h":0.45}`, fractions 0-1 of the picture; only that region is used and covers the area), optional `"fit": "width"` (fit the whole picture, or the whole crop region, into the area with black bars; at most 15% empty). Images have no sound. `highlight`: `src`, `duration`, and either `box` (+ optional `crop`, `fit`) for a poster or photo, or `sentence` / `quote` (+ optional `lines`, `crop` "auto") for the page capture `page.png`: a red box on the picture, the outside darkened. `text_card` (emergency): `lines`, optional `highlight`, `duration`. Neither moves. See `visual-distribution.md` |
| `transition` (on a segment) | how it comes in: omit or `cut` (hard cut), or an FFmpeg xfade name (`fade`, `slideleft`, `smoothup`, `wipeleft`, `circleopen`, ... see `transitions.md`), with `transition_duration` (default 0.3 s). Overlapped time is removed, so the video gets shorter by that much |
| `audio` | `{"mode": "original"}` or `{"mode": "narration", "file": "재료/나레이션.wav", "original_volume": 0.2, "narration_volume": 1}`. Optional in either mode: `bgm` (a song file in `재료/`, needs the `sources.json` record with `human_approved: "yes"`, see `audio-extras.md`), `bgm_db` (default -20, against the speech), `bgm_fade_in` (default 1), `bgm_fade_out` (default 2) |
| `captions[]` | `start`, `end` (seconds on the OUTPUT timeline, after overlaps are removed), `text`. White text with a dark outline near the bottom of the video area |
| `sfx[]` | `file`, `at` (output seconds), `volume_db` (default -12; keep -12 to -20 so speech stays clear), optional `start`, `duration` (part of the file), `fade_in`, `fade_out` |
| `subtitle_position` | where captions go: `inside` (default: bottom of the video area), `bar` (same place with a black translucent strip behind the text; an option the user may choose, not a recommendation), `below` (under the bottom note; the user's choice only, see "Visual distribution") |
| `loudness` | `target` (default -19 LUFS), `true_peak` (default -1.5) |
| `logo` | optional path to the logo picture. If omitted, `재료/logo.png` (or `logo.jpg`) is used, and if that is missing the default KAIST logo of this skill (`assets/kaist-logo.png`). `false` means no logo (only when the user asks) |
| `_...` keys | ignored (use for notes) |

Timeline rule: segment i starts at (sum of earlier segment lengths) minus (sum of earlier transition_durations). The script prints these starts. Captions, sfx times and narration use the output timeline; narration always starts at 0 s, so make clips a little longer by the transition time to keep the same words visible.

Examples (format references only): `examples/딸기파티.spec.json` (video clips with transitions, original sound; flow A) and `examples/상량식.spec.json` (article photos + Typecast narration + captions; flow B). They point at files that the collect scripts and `typecast.ps1` produce. Copy one to a result folder and change the paths and text.
