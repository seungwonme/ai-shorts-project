# Flow A: an existing YouTube video -> shorts

Read when the user gives a YouTube URL and wants a short made from that video. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

1. Collect: `scripts/collect-video.ps1 -Url "<url>"`. It writes `재료/<id>/video.mp4` (1080p or less), `meta.json` (title, channel, date, license text, credit line), `transcript.txt` (Korean subtitles with `[seconds]` at the start of each line; auto subtitles may contain wrong words, say so) and the raw `.vtt` files. If no Korean subtitles exist, there is no transcript: pick segments by looking at frames (`ffmpeg` can extract still pictures) and tell the user.
2. Pick 2-4 segments (about 45-60 s in total) by reading `transcript.txt`: a hook near the start, the main moment, a closing line. Note in/out seconds for `spec.json`. Start each segment at the start of a sentence, end after it finishes (add about 0.3 s). Check against `meta.json.duration`.
3. Send the approval message in the fixed order of the approval message template in `approval-and-render.md` (title, bottom note, segment list with the transcript lines, checklist; the logo is added by default and is not asked about) and wait for approval.
4. Write `spec.json` (`examples/딸기파티.spec.json` shows the format; its `src` is `재료/<id>/video.mp4`), render, report. The video keeps its own sound (`"audio": {"mode": "original"}`). Captions only if the user wants them.
4b. Optional BGM: see `audio-extras.md` (same for both flows). Skip it unless the user brings a song.
5. Say the credit line from `meta.json` (for example "출처: YouTube KAIST") and the license text it carries. Only reuse videos the user may reuse.

To change only the title of a finished short: edit `title` in the existing `spec.json`, show the two new lines, wait for approval, render again.
