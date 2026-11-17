# Worked reference: KAIST event short with the fixed frame

Read when the first frame shows a logo and two title lines on top, a video window in the middle and a note line at the bottom (the KAIST event-short layout), or when `analyze.ps1` printed `화면 틀: ... (measured ...)` with fixed bands of about 30% above and below.

## The material

- https://www.youtube.com/shorts/IyGoQWBCanQ (1080x1920) and https://www.youtube.com/watch?v=dNSjAU91Hnk use the same frame: only the middle window moves, logo, title and note stay.
- The layout numbers of that frame live in `../../kaist-shorts-make/references/TEMPLATE.md` (video window y582-1337 of 1920). Do not copy numbers from here: measure the video in front of you.

## What the measurement found

- `analyze.ps1` (default `-VideoBox auto`) sampled 16 pictures: rows that never changed covered about 30% at the top and 30% at the bottom, the moving rows 40%; the box came out as `0,0.306,1,0.388` (two rows trimmed inside the fixed bands), within 0.3% of the template's `0.303,0.394`.
- Cut detection inside that box: 11 cuts on `IyGoQWBCanQ` and 3 on `dNSjAU91Hnk`. On the whole picture the fixed bands hide most changes (10 and 1 cuts): a fixed frame lowers the score of every real cut.
- The same box is what the template says for the layout, which is why the measure is trusted when it lands there. A landing far from the template is not wrong by itself: it means a different frame.
- Font: the two title lines (white, then teal) are a heavy sans-serif with square stroke ends and wide letters. Gmarket Sans Bold looked closest by eye (not confirmed); the candidates list carries names like this with a reason, and the person confirms on 눈누 or by overlaying the candidate on `title-crop.png`.

## What made it good

- The frame was found from the video, not assumed: the same code returns the whole picture for a video with no frame (see `example-full-frame-and-other-layouts.md`).
- The result states its source (`measured`), so the report can say how sure it is.

## Reproduce on a new video

1. Run the analysis without `-VideoBox` and read the `화면 틀:` line and `analysis.json` `video_box_detail`.
2. Open `first-frame.png`: the fixed bands must be outside the printed box and the moving picture inside.
3. If the source says `fallback-kaist-template`, the measure was unsure: check the picture, then either accept the template layout (when it is a KAIST event short) or pass `-VideoBox none` or your own measured numbers.
4. Compare the cut count with and without the box; a frame that is really there changes it a lot.
