# Logo (added by default)

Read when the logo file, a different logo, or `-NoLogo` comes up. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

The KAIST logo is added to every short by default. Do not ask about it and do not list it in the approval message.

- `render.ps1` picks the logo in this order: `spec.logo` (a path), `재료/logo.png` (or `logo.jpg`), then the default file that ships with this skill, `assets/kaist-logo.png`. A user who wants another logo file (for example a department logo or a high-resolution official file) saves it as `재료/logo.png`.
- Render without a logo only when the user asks for it: add `-NoLogo` to the render command or set `"logo": false` in `spec.json`.
- Never download, copy or redraw a logo from other sources yourself, and never recolor or distort it.
- The logo is KAIST's registered trademark. The KAIST UI page (https://kaist.ac.kr/kr/html/kaist/010401.html) says it may not be used for commercial purposes and that the files are provided for education and administrative purposes. Say this in one sentence only if the user asks about the logo.

The script scales the logo to 344 px wide and centers it in the logo box (x368, y106-218). A white-background JPG gets its white made transparent.
