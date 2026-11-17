# Worked reference: videos without the KAIST frame

Read when `analyze.ps1` printed `화면 틀: 없음` (`full-frame`), or the video is horizontal, or the box it measured does not look like a KAIST event frame.

## Three layouts seen in the validation set

| Layout | Video | Result of `-VideoBox auto` | Cuts |
|---|---|---|---|
| Vertical interview, small logo overlay, no frame | https://www.youtube.com/watch?v=zJmPEh2XVjE (480x854) | `full-frame`: no fixed band, the whole picture moves | 10 |
| Horizontal news clip, 1920x1080 | https://www.youtube.com/watch?v=aM5JQya12mc | `full-frame` | 14 |
| Horizontal slide video with a fixed header and footer | https://www.youtube.com/watch?v=670MWR_xx2w | `measured`, box `0.111,0.216,0.844,0.627` (header and footer bands 18% and 12%) | 3 |

## What made the decisions right

- A fixed KAIST box applied to the interview video crops the middle 39% of a picture that has no frame and gave a different count (11 instead of 10); the measure returns the whole picture there.
- For the horizontal clip the vertical KAIST numbers do not apply at all; `full-frame` is the right answer even though the count happens to match.
- For the slide video the box follows the real fixed elements (title line and footer logo), so slide changes are compared where they happen.

## Reproduce on a new video

1. Run the analysis, read the `화면 틀:` line, open `first-frame.png` and `contact-sheet.jpg`.
2. `full-frame` and nothing fixed in the picture: accept. A fixed overlay that covers a small corner (a logo) is not a frame.
3. `measured` with bands you can see: accept. Bands you cannot see: run again with `-VideoBox none` and compare.
4. Say in the report which source the box had (`measured`, `full-frame`, `fallback-kaist-template`, `given`).
