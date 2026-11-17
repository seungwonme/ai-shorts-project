# Worked reference: flow A, picking segments from a long event video

Read when building a flow A short (an existing YouTube video, original sound) and choosing the in/out seconds. `examples/딸기파티.spec.json` is the format of the finished spec; this file explains the choices.

## The material

- https://www.youtube.com/watch?v=i-jQHQcNdWI, KAIST channel, 487 s, license text "Creative Commons Attribution (reuse allowed)", credit line from `meta.json` (`출처: YouTube KAIST`). Korean auto subtitles exist, so `transcript.txt` has `[seconds] text` lines.
- A strawberry-party event with a 20-second tongue-twister challenge, filmed over several attempts.

## The three segments and why

| Segment | In-out (s) | Role | Why this span |
|---|---|---|---|
| 1 | 183.92-186.72 (2.8 s) | hook | the host sets up the challenge ("마이크 들어주시고") and the viewer learns there is a time limit |
| 2 | 196.73-206.84 (10.1 s) | first attempt | the first attempt, from the start signal to the end of the sentence |
| 3 | 285.49-317.12 (31.6 s) | main moment and close | the explained rule, the countdown, the long attempt, the applause |

Total about 44 s inside the 45-60 s pattern. Title "20초 안에 읽어라" (white, sets up) over "딸기 잰말놀이" (teal, the keyword). Bottom note "↓ 풀영상은 KAIST 채널" because the clip comes from a longer video. Transitions: `fade` then `slideleft`, 0.3 s each, one kind of short transition.

## What made it good

- Each segment starts at the start of a spoken sentence and ends right after one finishes (about 0.3 s of tail), so no word is cut.
- A hook near the start, the event's own moment in the middle, a reaction at the end.
- Original sound kept (`"audio": {"mode": "original"}`), loudness normalised by the renderer, source credit given for the description.
- Auto subtitles in this transcript contain wrong words ("스트라이크 스트로베리"); the choice of span is made from timing and meaning, and the user is told the words may be wrong.

## Reproduce on a new video

1. `collect-video.ps1`, read `transcript.txt` and `meta.json.duration`.
2. Choose 2-4 spans (45-60 s total): a hook, the main moment, a closing line; write `in` and `out` on sentence boundaries.
3. Send the approval message with the spans and the transcript lines they contain.
4. Without Korean subtitles, extract still pictures with `ffmpeg` and choose by looking; say so.
