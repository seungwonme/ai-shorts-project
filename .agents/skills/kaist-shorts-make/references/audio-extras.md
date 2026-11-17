# BGM and sound effects

Read for every short (sound effects are added by default) and when the user mentions background music. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

## BGM (optional, both flows)

You never search for, download, or pick music. The user picks it. 17 songs are preinstalled in `재료/bgm/`: let the user choose from the preinstalled list (`재료/bgm/곡목록.md`). The folder ships with the GitHub zip and is tracked in git. A song the user brings goes in `재료/` (for example `재료/배경음.mp3`). Do not add other music files to the repository: `.gitignore` skips mp3/wav/m4a except the preinstalled `재료/bgm/` and `재료/sfx/` files.

1. Ask only if the user mentions background music. Otherwise leave BGM out (the approval message says `없음`).
2. The user tells you the file name and the facts they checked on the song's page: title, creator, URL, license name (and credit wording if the license asks for one), download date. Never guess a license from a song's name or from what you remember; if the user does not know, the song is not approved yet.
3. Write those facts into the `sources.json` in the same folder as the song file (`재료/bgm/sources.json` for the preinstalled songs, whose records already exist with `human_approved: "no"`; only `013_Snack_Time.mp3` is `yes`), in the `bgm` list. Create the file if there is none; if it exists, add to it without touching the other entries:

```json
{"bgm": [{"file": "배경음.mp3", "title": "곡 이름", "creator": "만든 사람", "url": "https://...", "license": "라이선스 이름", "downloaded": "2026-11-16", "human_approved": "no"}]}
```

4. Put the BGM line in the approval message (template item 8). Change `human_approved` to `"yes"` only after the user clearly says they checked the terms and approve using the song. `render.ps1` stops with a Korean message while any field is empty or `human_approved` is not `yes`; do not edit the gate away.
5. In `spec.json` add to `audio`: `"bgm": "재료/배경음.mp3"`. Optional: `"bgm_db"` (level against the speech, default -20), `"bgm_fade_in"` (seconds, default 1), `"bgm_fade_out"` (seconds, default 2). The song is looped when it is shorter than the video and cut when longer. Loudness stays at -19 LUFS for the whole mix.
6. Credit line: if the license asks for a credit, add it to the credit line you give at the end.

## Sound effects (added by default, both flows)

Add a few sound effects to every short without being asked; leave them out only when the user says so. Start with the 4 preinstalled CC0 sounds in `재료/sfx/` (already approved, records in `재료/sfx/sources.json`): `whoosh-03.mp3` for a transition, `pop-10.mp3` when a highlight box appears, `ding-02.mp3` when a date piece appears, `click-03.mp3` when the sentence changes. If a moment needs a sound none of them fits, choose a short English word yourself (do not ask the user for one) and get it through steps 1-2 below; a newly downloaded sound needs the user's check (step 4) before it can be rendered, so ask for it in the approval message. Follow the spacing rule of step 5.

Sound effects are found and downloaded **only through the audio path of `openverse.ps1`**. Never use web search, direct file addresses or any other site for sounds. BGM is separate: it stays human-chosen (the BGM part above).

1. Decide the sounds first, one per purpose (for example a whoosh for a cut or transition, a pop when a highlight box appears, a ding when the date piece appears, a click when the sentence changes). Search **once per sound** (the same query is saved in `재료/sfx/search-<word>-cc0.json` and never called twice; the tool waits 3 seconds between calls):
   `scripts/openverse.ps1 -SearchSfx "whoosh" -OutDir 재료/sfx`  (CC0 only; `-License cc0,by` only when the user asks; 5 seconds or less; at most 10 candidates with length, title, creator, license, original page).
2. Pick a number and download: `scripts/openverse.ps1 -DownloadSfx 3 -UsedFor "장면 전환" -OutDir 재료/sfx`. It checks the original page is alive (404 or 410 is refused), downloads only from `cdn.freesound.org` (https, at most 2 MB, mp3 only), writes `재료/sfx/<word>-NN.mp3` and a record in `재료/sfx/sources.json` (`sfx` list: title, creator, creator_url, foreign_landing_url, license, license_url, downloaded, found_via, sha256, `human_approved: "no"`, used_for, `suggested_volume_db`). Sound files are never committed (`.gitignore` skips mp3).
3. If the tool says the Openverse limit was reached (429), tell the user in plain words: wait a minute and try again, today's limit is 200 calls, and many students on the same internet share one limit.
4. Put the sound effects in the approval message (template item 8, after the BGM line): which sound, where it plays (transition, highlight box appears, ...), its license and `human_approved` status. Set `"human_approved": "yes"` only after the user says they checked the original page (`scripts/openverse.ps1 -ConfirmSfx "whoosh-03.mp3" -UserSaid "<the user's words>" -OutDir 재료/sfx`). `render.ps1` stops with a Korean message when a sound in `spec.sfx` has no complete record (title, creator, license, original page, download date) or no approval, or has a license other than CC0 / CC BY. The credit line goes into `credits.txt` ("효과음: ..." with 표기 선택 for CC0).
5. In `spec.json`: `"sfx": [{"file": "재료/sfx/whoosh-03.mp3", "at": 6.2, "volume_db": -20}, ...]` (`at` = the output time of the cut or box in seconds; use the record's `suggested_volume_db`, which puts the effect's peak about 14 dB under the speech peak so the narration stays clear; keep it in -12 to -20 range for loud sounds). **At most one effect per 4 seconds and never two within 0.5 s (`render.ps1` stops otherwise):** pick a few moments (the first poster, the first highlight box, the date piece, one transition) instead of every piece or every transition; give each moment one sound, not a pop and a click together.
6. Backup: `scripts/elevenlabs.ps1 -Sfx "short soft whoosh" -SfxSeconds 0.8` only calculates credits (about 200 credits per generation) and prints the license warning; it does not generate. **A sound made with the ElevenLabs free plan cannot go onto the KAIST channel; a paid plan is needed.**
