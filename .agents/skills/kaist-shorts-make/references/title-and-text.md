# Writing the title and text

Read when writing the two title lines, the bottom note and the captions. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

- Title: exactly 2 lines, short. About 12-13 Korean characters per line fit the layout at full size; longer lines are shrunk automatically and look smaller than the KAIST original, so prefer shorter wording. Line 1 sets up (white), line 2 is the hook or the keyword (teal). The line to emphasize is the teal one (`"color": "teal"`); the order of colors may be swapped.
- Bottom note: `"↓ 풀영상은 KAIST 채널"` for clips from a longer video, `"↓ 자세한 소식은 KAIST 뉴스"` for news-style shorts. The arrow is drawn from a picture, so write it as the first character.
- Captions: short, one line each (about 20 characters or less, longer ones are shrunk). Match times to the narration. Do not invent facts, numbers, quotes or names; use only what is in the user's material or sources they give. Mark anything you are unsure of and ask.
- Length: 45-60 seconds is the KAIST pattern. Segment lengths are your choice; tell the user the total.
- Sound: video clips keep their own sound (`"audio": {"mode": "original"}`). With narration, use `"mode": "narration"`; clip sound is lowered to 0.2. Background music and sound effects: follow `audio-extras.md`. Loudness is normalized to -19 LUFS automatically.
