# Worked reference: article whose lead image is a text poster (news 69410)

Read when `measure-image.ps1` reports blocks (title, logos, date, QR) on the article's lead image, or when `render.ps1` stops a tall picture piece for text under the caption. This is one finished example of the judgement; measure your own picture and adapt, never copy the numbers unchecked.

## The material

- Article https://news.kaist.ac.kr/news/html/news/?mode=V&mng_no=69410, one image `img-01.jpg` (800x1000, a symposium poster): series title, English subtitle, theme line with five keywords, six host logos, date and venue, QR code and address at the very bottom.
- The poster is the only picture, 26 sentences of body text follow. A short of 13 pieces needs several different screens, so the poster is shown in parts.

## What `measure-image.ps1` found (the judgement to reproduce)

- Eight text blocks by height (fractions of the picture): 0.03-0.097 host line and "international symposium", 0.16-0.283 the big title, 0.303-0.33 and 0.35-0.37 English title, theme line and keywords, 0.45-0.47 the host-institutions label, 0.49-0.657 the six logos, 0.75-0.823 date and venue, 0.883-0.957 QR and address.
- Passing crops, all at the 1.43:1 ratio of the video area, text whole at the sides, important blocks in the upper 75%:

| Name | x | y | w | h | Shows |
|---|---|---|---|---|---|
| `part-1` | 0.066 | 0.019 | 0.86 | 0.482 | host line through keywords |
| `part-2` | 0.031 | 0.439 | 0.938 | 0.526 | logos, date and venue |
| `detail-1` | 0.126 | 0.01 | 0.74 | 0.414 | the host line and "international symposium" only |
| `detail-3` | 0.031 | 0.393 | 0.938 | 0.526 | host label and logos |
| `detail-4` | 0.068 | 0.492 | 0.86 | 0.482 | date and venue only |

- The QR block is not croppable: whatever window contains it puts it under the caption. The tool marks it, and the right move is to leave it out.
- A hand-checked set (`examples/crops-69410.example.json`: `title`, `keywords`, `logos`, `date`) agrees with the measured ones within 0.01. The measured set came first in practice; the hand set only confirms it.

## What made it good

- Every crop keeps at least 3% margin at both sides, so no letter is cut, and never zooms below 70% of the width, so logos stay readable.
- The first piece is the lead image through `crop: "poster"` (7% side margin from the top of the poster), then three sentence highlights, then a poster part, repeating; the same part appears at most twice and never twice in a row.
- A crop without measuring (the uncropped poster as a plain `image` piece) is stopped by the caption-zone check, which is correct here: the text blocks sit under the caption.

## Reproduce on a new article

1. `measure-image.ps1 -Image 재료/기사-<id>/img-01.jpg -Write`, then open the picture and look at the blocks it listed.
2. Keep the crops that pass; rename them to what they show if you want (`title`, `date`).
3. Use `named:<name>` for different regions at lines about that content, one region per piece, at most 3 sentence highlights between picture pieces.
4. To reuse the example numbers on this same poster only: check `img-01.jpg` is 800x1000 and shows this poster, copy `examples/crops-69410.example.json` to `재료/기사-69410/crops.json`, and run the render; the checks confirm they fit.
5. Different poster: measure it again. Numbers copied from another picture fail the checks or cut letters.
