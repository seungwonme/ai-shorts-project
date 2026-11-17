# Logo (not shipped with the project)

Read before the first render of a project, and whenever the logo file or `-NoLogo` comes up. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

The official KAIST logo file is not part of this project. `render.ps1` looks for `재료/logo.png` (or `logo.jpg`, or `spec.logo`). Before the first render, check that it exists. If it does not:

1. Tell the user in plain Korean: the KAIST logo is not included; download "KAIST 로고" from the official KAIST UI page https://kaist.ac.kr/kr/html/kaist/010401.html (high-resolution files may need the KAIST portal login) and save it into the `재료` folder as `logo.png` (a PNG with a transparent background is best; the English page https://kaist.ac.kr/en/html/kaist/011901.html also has a logo download). The page says the UI is a registered trademark that may not be used for commercial purposes, and high-resolution files are provided for education and administrative purposes. Follow KAIST's UI guidelines; do not recolor or distort the logo.
2. Offer the other option: render without a logo. Only if the user clearly agrees, add `-NoLogo` to the render command (or set `"logo": false` in `spec.json`).
3. Never download, copy or redraw the logo from other sources yourself.

The script scales the logo to 344 px wide and centers it in the logo box (x368, y106-218). A white-background JPG gets its white made transparent.
