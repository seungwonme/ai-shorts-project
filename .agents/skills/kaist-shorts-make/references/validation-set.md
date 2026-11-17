# Validation set for the measured heuristics

Read when you change a heuristic (frame detection in `analyze.ps1`, crop measurement in `measure-image.ps1`, the picture checks in `render.ps1`), or when a student's video or article is handled wrongly and you want to know what was checked. Measured on macOS (PowerShell 7, ffmpeg-full 9.0.2); Windows PowerShell 5.1 is not verified (`practice/VM-검증-목록.md`, items 43-45).

The rule behind this file: values that belong to one source are measured for that source, heuristics are labeled and overridable, and a heuristic is only trusted after it has been run on a set that is not one sample.

## Heuristics and their overrides

| Heuristic | Where | Thresholds | Override |
|---|---|---|---|
| Fixed frame bands of a video (cut detection runs inside the moving area only) | `analyze.ps1` `Measure-VideoBox` | 16 pictures, a pixel is static if it differs by at most 10, a row is fixed at 97% static, a row moves at under 85% static, fixed bands must cover at least 15% of the height, the moving area must be 15-85% of the height and at least 40% of the width | `-VideoBox none`, `-VideoBox kaist-template`, `-VideoBox left,top,width,height`. If the measure is unsure: a vertical video falls back to the KAIST event-short frame (`references/TEMPLATE.md`), anything else uses the whole picture, and the result says which (`video_box_detail.source`) |
| Text-poster crops of an article picture | `measure-image.ps1` | edge = brightness step above 40; a row is "active" above 1.2% edges; blocks merged across gaps of 1.8% of the height; photo-like at 20% overall edges; crop width at least 70% of the picture, 4% margin around the block; block must sit in the upper 75% of the crop | the person looks at the picture and writes `crop` numbers by hand; nothing is proposed for photos |
| Caption-zone and side-cut checks on picture pieces | `render.ps1` `Test-PicPiece`, constants `$PIC_*` | tall pictures only (height at least 1.1x width); only "text-poster-like" crops (at least 30% of rows without edges); lower 25% edge density at least 0.03 and at least 0.7x the upper 75% = stop; side strip density above 0.03 = stop, except on a side where the crop reaches the picture's own border | `"allow": {"caption_text": "<reason>", "edge_cut": "<reason>"}` on the piece (reason required and printed) |
| Lead image first piece (`crop: "poster"` / `"lead"`) | `render.ps1` `Resolve-PosterCrops` | 7% side margin, top of the image, height by the 1080:756 ratio; an image wider than 2.4:1 stops with a Korean message ("leave the lead image out") | use a measured `named:` crop of `img-01.jpg` as the first piece, or start with a sentence `highlight` |

## Set 1: videos (analysis, cuts found)

Baselines: the whole picture, and fixed KAIST template numbers for every video; "auto" = the measured frame.

| Video | What it is | Whole picture | Fixed KAIST numbers | auto (frame measured) |
|---|---|---|---|---|
| https://www.youtube.com/shorts/IyGoQWBCanQ | KAIST event short, KAIST frame | 10 | 11 | **11**, box `0,0.306,1,0.388` (measured) |
| https://www.youtube.com/watch?v=dNSjAU91Hnk | KAIST channel short, KAIST frame | 1 | 3 | **3**, same box (measured) |
| https://www.youtube.com/watch?v=zJmPEh2XVjE | KAIST channel interview short, vertical, no frame (small logo overlay) | 10 | 11 (wrong: crops the middle 39% of a picture with no frame) | **10**, whole picture (`full-frame`) |
| https://www.youtube.com/watch?v=aM5JQya12mc | news clip, 1920x1080 horizontal | 14 | 14 (applies vertical numbers to a horizontal video) | **14**, whole picture |
| https://www.youtube.com/watch?v=670MWR_xx2w | KAIST IP institute promo, 1920x1080 slides with fixed header and footer | 3 | 3 | **3**, box `0.111,0.216,0.844,0.627` (measured) |

## Set 2: news articles (flow B, render result)

Each article gets a test spec of the kind a model writes without measuring ("unmeasured": first piece `crop: "poster"`, three sentence highlights, then an article picture without crop, three times) and a "measured" spec that uses `measure-image.ps1` crops. The baseline column ran the same spec through the renderer as it was before the measured-crop change, for comparison. Silent placeholder narration, `-NoLogo`. PASS = the render finished; STOP = `render.ps1` stopped on a rule.

| Article | Lead image | Baseline renderer, unmeasured spec | Current renderer, unmeasured spec | Current renderer, measured spec |
|---|---|---|---|---|
| https://news.kaist.ac.kr/news/html/news/?mode=V&mng_no=69410 (the demo article) | tall text poster 800x1000 | STOP (pieces with the uncropped poster) | STOP (same, correct: the poster needs a measured crop) | PASS |
| ...mng_no=69431 | ordinary photo 800x437 | PASS | PASS | PASS |
| ...mng_no=69351 | photo 700x768 | STOP (false: photo read as text) | PASS | PASS |
| ...mng_no=69470 | photo 800x592 | STOP (false) | PASS | PASS |
| ...mng_no=69490 | photo 700x737 | STOP (false) | PASS | PASS |
| ...mng_no=69510 | small tall poster 391x482 | STOP | STOP (correct: the first-piece crop puts text under the caption; use a measured `named:` crop) | PASS |
| ...mng_no=69570 | photo 603x402 | STOP (false) | PASS | PASS |
| ...mng_no=69590 | photo, very long page (15,080 px) | STOP (false: crop of a long page judged by fractions) | PASS | PASS |
| ...mng_no=69210 | flat banner 3.4:1 (other photos follow) | PASS without the lead piece; STOP with it | PASS without it; with it a clear Korean stop | PASS |
| ...mng_no=69230 | flat banner 3.8:1 | same as 69210 | same | PASS |
| mng_no=99001 (synthetic: 69431 with its images removed) | none | PASS | PASS | PASS |

Counts, 11 articles: baseline 4 PASS, unmeasured 9 PASS (the two STOPs are real text posters that need a crop), measured 11 PASS. No article in the news list had zero images, so the no-image case is synthetic (the page capture of 69431 with `images` emptied and the `img-*` files removed). `mng_no=69270` and `69310` were collected but their page capture timed out (60 s), so they are not in the set.

The three demo paths give byte-identical output where the input is the same as before:

- Flow A, https://www.youtube.com/watch?v=i-jQHQcNdWI with `examples/딸기파티.spec.json`: the video stream md5 is identical to the earlier render.
- Flow B example `examples/기사캡처.spec.json` (69410, named crops from `crops-69410.example.json`): the video stream md5 is identical to the render with hand-named crops.
- Analysis of `IyGoQWBCanQ`: 11 cuts (same as with the fixed KAIST numbers).

## Re-running

- Videos: `analyze.ps1 -Source <mp4 or url> -NoOpen` (add `-VideoBox none` to compare). Read the `화면 틀:` line and `analysis.json` `video_box_detail`.
- Articles: collect (`collect-article.ps1`, `capture-article.ps1`), `measure-image.ps1 -Image ... -Write` for every `img-NN.jpg`, build a spec, `render.ps1 -Spec ... -NoOpen -NoLogo`.
- A heuristic change is only accepted when the counts above do not get worse and the demo paths keep the same output.
