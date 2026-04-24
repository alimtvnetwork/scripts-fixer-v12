---
name: Do not read assets/ folder files
description: Avoid loading assets/demos/*.svg, *.png, *.gif into context — they are large generated artifacts. Reference by path only.
type: constraint
---
The `assets/` folder (especially `assets/demos/`) holds generated SVG/PNG/GIF demos and brand icons. These are large and waste context.

**Rules:**
- Never `code--view` files under `assets/` to "look at" them.
- Never read `assets/demos/build-demos.py` output files.
- When updating demos, edit `assets/demos/build-demos.py` and re-run it; do not inline-read the SVGs.
- Reference asset paths in README via `<img src="assets/demos/...">` — do not paste their content.

**Why:** SVG demos are thousands of lines each; a single read can blow the context window for no information gain.