# Worked reference: article with ordinary photos

Read when `measure-image.ps1` says "photo" (people, scenery: edges everywhere) or the picture is not tall. Photos need no crop table; the judgement is about the first piece, repetition and faces.

## What the material looks like

- Typical KAIST news articles carry 2-5 landscape or near-square photos (for example 800x437, 700x768, 800x592), each with a caption in `article.md`.
- `measure-image.ps1` proposes nothing for them: a photo has no text blocks to keep whole. `render.ps1` skips the caption-zone and side-cut checks for such pictures, so a photo piece without `crop` fills the area from the center and passes.

## What made it work

- First piece: `crop: "poster"` on `page.png` takes the top of the lead photo with 7% side margin. Do the same, then alternate three sentence highlights with one photo piece.
- Rotate through the article's photos (`img-01.jpg`, `img-02.jpg`, ...), the same photo at most twice, never twice in a row.
- To show part of a photo (a person at the side, an object), look at it and write `crop` numbers measured on that photo, with the real pixel ratio between 1.0:1 and 2.0:1 and the subject in the upper 75%. Never isolate, distort or mock a face; the 초상권 reminder stays in the final answer.
- A photo that is not directly about the line is not used as filler: fall back to a page-capture sentence highlight.

## Reproduce on a new article

1. Run `measure-image.ps1` on every `img-NN.jpg`; note which ones are photos and which are text pictures.
2. Photos: use plain `image` pieces. Text pictures (charts, posters): follow `example-article-poster-69410.md`.
3. A lead image wider than 2.4:1 (a banner) cannot be the first piece: `render.ps1` stops with a Korean message; start with the first sentence highlight and use the photos further down.
4. Render; if a photo piece is stopped, read the message before adding `allow`.
