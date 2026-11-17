# Worked reference: article without images

Read when `page-boxes.json` lists no images (or only a flat banner) and the article folder has no usable `img-NN.jpg`.

## What changes

- There is no lead image, so there is no poster piece: the first piece is the first sentence `highlight` of `page.png`.
- The "at most 3 body-sentence highlights in a row" limit only applies when the article has an image; here every piece is a sentence highlight, and variety comes from different sentences.
- The required number of different screens (at least half the pieces) is met by different sentence boxes: each sentence number is its own screen.

## What made it work

- Pick short sentences (about 110 characters or fewer; a sentence of 8 lines does not fit one screen and `render.ps1` asks for `lines [first, last]`).
- Move down the page in reading order; the same sentence at most twice, never twice in a row; neighbouring sentences whose boxes overlap by half count as one screen, so skip one.
- Close the short on a sentence that is not at the very end of the page (the last sentences cannot be lifted above the caption zone).
- A photo supplement (template item 5 of the approval message) is proposed only when a script line has a directly related photo; otherwise write "사진 보충 없음".

## Reproduce on a new article

1. Read the sentence list in `page-boxes.json`; choose sentences that carry the script lines, one piece each, 2-4 seconds per piece.
2. Build the visual table with all rows as page-capture highlights and say so in the 4th cell.
3. Render and fix what `render.ps1` reports.
