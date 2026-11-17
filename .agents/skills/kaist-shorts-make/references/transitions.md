# Transitions

Read only when the user wants a transition between pieces. (Routing and invariants live in `../SKILL.md`; this file is the detail.)

- **Default: none** (a hard cut). Add a transition only when the user wants one, or when the approval message says so.
- Write it on the piece that comes in: `"transition": "fade", "transition_duration": 0.4` (or `"transition": {"name": "fade", "duration": 0.4}`). The overlap time is removed from the timeline, so add the transition length to the earlier piece's `duration` (the script prints the piece starts). Names are FFmpeg xfade names, for example `fade`, `fadeblack`, `dissolve`, `slideleft`, `smoothup`, `wipeleft`, `circleopen`. An unknown name or a duration outside 0.1-1 s stops the render with a Korean message.
- **Recommendation: short (0.3-0.5 s), and one kind for the whole video. Do not use a different transition on every cut** (it looks busy). `fade`, `slideleft` and `smoothup` are safe; `zoomin` can flash a strong color when the picture has a big colored letter.
- A transition and the highlight box: the box fades in 0.3 s after its piece starts, so keep `transition_duration` at 0.5 s or less and the box appears just after the new piece is fully visible. Captions, sound effects and narration use the output timeline (after the overlaps are removed), so put a transition sound effect at the piece's start time minus half the transition.
