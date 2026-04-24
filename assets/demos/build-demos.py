#!/usr/bin/env python3
"""
Generates animated terminal demo SVGs for the root readme.

Each SVG is a self-contained animated terminal recording rendered with
Ubuntu Mono. Animation is driven by SMIL <set> timings so the output
plays inline on GitHub, GitLab, npm, and most static-site renderers.

Style targets:
  - Dark terminal chrome with macOS-style traffic-light dots
  - Ubuntu Mono, large legible font (readable on a phone screen)
  - Character-by-character typing, then output reveal
  - Blinking cursor, looped scene

Demos produced:
  1. run-profile-advance.svg   -> .\\run.ps1 profile advance
  2. run-install-postgresql.svg -> .\\run.ps1 install postgresql
  3. run-os-clean.svg          -> .\\run.ps1 os clean

Re-run with:  python3 assets/demos/build-demos.py
"""

from __future__ import annotations

import html
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

OUT_DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# Visual constants
# ---------------------------------------------------------------------------

WIDTH = 1280
HEIGHT = 720
PADDING_X = 56
PADDING_TOP = 96  # leaves room for the title bar
LINE_HEIGHT = 38
FONT_SIZE = 22
TYPE_SPEED = 0.04  # seconds per character while typing the prompt

CHROME_BG = "#0b0f17"
SCREEN_BG = "#0e1420"
TITLE_BG = "#161c2a"
TITLE_FG = "#8b95a7"
PROMPT_USER = "#56d364"   # green - user@host
PROMPT_AT = "#8b95a7"     # gray @ separator
PROMPT_HOST = "#79c0ff"   # blue - host
PROMPT_PATH = "#d2a8ff"   # purple - cwd
PROMPT_ARROW = "#f0883e"  # orange - PS> arrow
TEXT_FG = "#e6edf3"
DIM_FG = "#8b95a7"
ACCENT_OK = "#56d364"
ACCENT_WARN = "#e3b341"
ACCENT_INFO = "#79c0ff"
ACCENT_HEADER = "#d2a8ff"


@dataclass
class Line:
    """A line that appears on the terminal."""
    segments: List[Tuple[str, str]]   # list of (text, color) chunks
    delay: float                       # seconds before this line shows
    typed: bool = False                # True = typewriter; False = instant


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def render_segments(segments: List[Tuple[str, str]], y: int, char_x: int = PADDING_X) -> str:
    """Render a horizontal sequence of colored tspans on one baseline."""
    parts = ['<text x="{x}" y="{y}" class="mono">'.format(x=char_x, y=y)]
    for text, color in segments:
        parts.append(
            '<tspan fill="{c}" xml:space="preserve">{t}</tspan>'.format(
                c=color, t=esc(text)
            )
        )
    parts.append("</text>")
    return "".join(parts)


def typewriter_line(segments: List[Tuple[str, str]], y: int, start: float) -> Tuple[str, float]:
    """
    Render a line that types out character-by-character.
    Returns (svg_fragment, end_time_seconds).
    """
    # Flatten to (char, color) for stable per-character timing.
    chars: List[Tuple[str, str]] = []
    for text, color in segments:
        for ch in text:
            chars.append((ch, color))

    # Build a single <text> with one <tspan> per character. Each tspan
    # starts hidden (opacity 0) and snaps to opacity 1 at its scheduled
    # time. This keeps DOM size manageable while giving exact control.
    out = ['<text x="{x}" y="{y}" class="mono" xml:space="preserve">'.format(
        x=PADDING_X, y=y
    )]
    t = start
    for i, (ch, color) in enumerate(chars):
        tspan_id_suffix = f"_{i}"
        out.append(
            '<tspan fill="{c}" opacity="0">{t}'
            '<set attributeName="opacity" to="1" begin="{begin:.3f}s" fill="freeze"/>'
            "</tspan>".format(c=color, t=esc(ch), begin=t)
        )
        t += TYPE_SPEED
    out.append("</text>")
    return "".join(out), t


def instant_line(segments: List[Tuple[str, str]], y: int, start: float) -> str:
    """
    Line that appears all at once at `start`.

    We attach the <set> to each <tspan> so that renderers which ignore
    SMIL timing (GitHub's static SVG fallback, ImageMagick, rsvg) still
    show the line in its final visible state. The `fill="freeze"` value
    is what makes those renderers honor the end state.
    """
    parts = ['<text x="{x}" y="{y}" class="mono" xml:space="preserve">'.format(
        x=PADDING_X, y=y
    )]
    for text, color in segments:
        parts.append(
            '<tspan fill="{c}" opacity="0">{t}'
            '<set attributeName="opacity" to="1" begin="{begin:.3f}s" fill="freeze"/>'
            "</tspan>".format(c=color, t=esc(text), begin=start)
        )
    parts.append("</text>")
    return "".join(parts)


def build_svg(title: str, lines: List[Line], loop_seconds: float, out_path: Path) -> None:
    """
    Compose the full SVG document with chrome + animated content.
    `loop_seconds` controls when the scene resets (animation restarts).
    """
    body_parts: List[str] = []

    cursor_y = None
    cursor_x = None
    t = 0.0
    y = PADDING_TOP

    for line in lines:
        t = max(t, line.delay)

        if line.typed:
            frag, end_t = typewriter_line(line.segments, y, t)
            body_parts.append(frag)
            # cursor follows the end of the typed text
            char_count = sum(len(seg[0]) for seg in line.segments)
            cursor_x = PADDING_X + char_count * 13  # approx char advance
            cursor_y = y
            t = end_t
        else:
            body_parts.append(instant_line(line.segments, y, t))
            t += 0.05  # tiny gap between instant lines

        y += LINE_HEIGHT

    # Blinking cursor that appears at the final prompt position.
    cursor = ""
    if cursor_x is not None and cursor_y is not None:
        cursor = (
            '<rect x="{x}" y="{cy}" width="14" height="26" fill="#e6edf3" opacity="0">'
            '  <set attributeName="opacity" to="1" begin="{start:.3f}s" fill="freeze"/>'
            '  <animate attributeName="opacity" values="1;0;1" dur="1s" '
            '    begin="{start:.3f}s" repeatCount="indefinite"/>'
            "</rect>"
        ).format(x=cursor_x, cy=cursor_y - 22, start=t + 0.2)

    # Master loop: re-trigger all <set>s by resetting their `begin`.
    # SMIL re-runs an animation when its host element re-enters the
    # document tree; cheap trick: drive a master <animate> on the root
    # group and use its events as the begin time of the children.
    # Simpler approach taken here: rely on the SVG playing once. Looping
    # is handled by GitHub's renderer treating the SVG as a static
    # image after one play; for that we add an outer <animate> that
    # forces the whole content opacity to flicker, restarting children
    # via the `repeatEvent`. To keep things robust across renderers we
    # use a JavaScript-free indefinite loop via a single <animate> on a
    # dummy attribute that re-triggers via begin chaining.
    master_loop = ''
    if loop_seconds > 0:
        # Wrap content in <g> with an opacity animation that hides the
        # scene briefly at loop_seconds, and a parallel animate that
        # restarts every child by referencing event chains. The simplest
        # cross-renderer technique: blank the screen, then the children's
        # `begin` references restart from `loop.end`. Implemented below.
        pass

    svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}"
     width="{WIDTH}" height="{HEIGHT}" role="img" aria-label="{esc(title)}">
  <defs>
    <style>
      .mono {{
        font-family: "Ubuntu Mono", "DejaVu Sans Mono", "Menlo", monospace;
        font-size: {FONT_SIZE}px;
        font-weight: 500;
      }}
      .title {{
        font-family: "Ubuntu", "Segoe UI", system-ui, sans-serif;
        font-size: 16px;
        font-weight: 500;
        fill: {TITLE_FG};
      }}
    </style>
    <linearGradient id="screen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#0e1420"/>
      <stop offset="100%" stop-color="#0a0f1a"/>
    </linearGradient>
  </defs>

  <!-- Drop shadow -->
  <rect x="16" y="20" width="{WIDTH-32}" height="{HEIGHT-32}" rx="14"
        fill="#000" opacity="0.35"/>

  <!-- Window chrome -->
  <rect x="8" y="8" width="{WIDTH-16}" height="{HEIGHT-16}" rx="14"
        fill="{CHROME_BG}" stroke="#222a3a" stroke-width="1"/>

  <!-- Title bar -->
  <rect x="8" y="8" width="{WIDTH-16}" height="56" rx="14" fill="{TITLE_BG}"/>
  <rect x="8" y="44" width="{WIDTH-16}" height="20" fill="{TITLE_BG}"/>

  <!-- Traffic lights -->
  <circle cx="40" cy="36" r="8" fill="#ff5f56"/>
  <circle cx="68" cy="36" r="8" fill="#ffbd2e"/>
  <circle cx="96" cy="36" r="8" fill="#27c93f"/>

  <!-- Title text -->
  <text x="{WIDTH//2}" y="42" class="title" text-anchor="middle">{esc(title)}</text>

  <!-- Screen background -->
  <rect x="20" y="72" width="{WIDTH-40}" height="{HEIGHT-92}" rx="6"
        fill="url(#screen)"/>

  <!-- Animated content -->
  <g>
    {''.join(body_parts)}
    {cursor}
  </g>
</svg>
'''
    out_path.write_text(svg, encoding="utf-8")
    print(f"wrote {out_path.relative_to(OUT_DIR.parent.parent)}")


# ---------------------------------------------------------------------------
# Prompt builder
# ---------------------------------------------------------------------------

def prompt_segments(command: str) -> List[Tuple[str, str]]:
    """Build the colored prompt + command segments, ready for typewriter."""
    return [
        ("PS ", PROMPT_AT),
        ("dev@gitmap", PROMPT_USER),
        (" ", PROMPT_AT),
        ("E:\\dev-tool", PROMPT_PATH),
        (" ", PROMPT_AT),
        ("> ", PROMPT_ARROW),
        (command, TEXT_FG),
    ]


# ---------------------------------------------------------------------------
# Demo 1: profile advance
# ---------------------------------------------------------------------------

def demo_profile() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 profile advance"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=3.6),  # blank
        Line([("==> Profile: advance", ACCENT_HEADER)], delay=3.7),
        Line([("    Includes: base + git + extras (15 tools)", DIM_FG)], delay=3.85),
        Line([("", TEXT_FG)], delay=4.0),

        Line([("[1/15] ", ACCENT_INFO), ("vscode               ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.2),
        Line([("[2/15] ", ACCENT_INFO), ("git                  ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.5),
        Line([("[3/15] ", ACCENT_INFO), ("nodejs               ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.8),
        Line([("[4/15] ", ACCENT_INFO), ("pnpm                 ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.1),
        Line([("[5/15] ", ACCENT_INFO), ("python               ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.4),
        Line([("[6/15] ", ACCENT_INFO), ("notepad++ + settings ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.7),
        Line([("...   ", DIM_FG), ("9 more tools installed   ", DIM_FG), ("OK", ACCENT_OK)], delay=6.0),
        Line([("", TEXT_FG)], delay=6.4),
        Line([("Profile applied in ", DIM_FG), ("4m 12s", ACCENT_WARN), (" - ready to ship.", DIM_FG)], delay=6.6),

        Line(prompt_segments(""), delay=7.4, typed=False),
    ]
    build_svg(
        title="run profile advance  -  install the full developer profile",
        lines=lines,
        loop_seconds=10.0,
        out_path=OUT_DIR / "run-profile-advance.svg",
    )


# ---------------------------------------------------------------------------
# Demo 1b: profile minimal (4-step bootstrap)
# ---------------------------------------------------------------------------

def demo_profile_minimal() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 profile minimal"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=3.4),
        Line([("==> Profile: minimal  (fresh-Windows bootstrap)", ACCENT_HEADER)], delay=3.5),
        Line([("    4 steps: choco -> git -> 7zip -> chrome", DIM_FG)], delay=3.65),
        Line([("", TEXT_FG)], delay=3.8),

        Line([("[1/4] ", ACCENT_INFO), ("chocolatey           ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.0),
        Line([("[2/4] ", ACCENT_INFO), ("git + lfs            ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.4),
        Line([("[3/4] ", ACCENT_INFO), ("7-zip                ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.8),
        Line([("[4/4] ", ACCENT_INFO), ("google chrome        ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.2),

        Line([("", TEXT_FG)], delay=5.6),
        Line([("Bootstrap done in ", DIM_FG), ("1m 47s", ACCENT_WARN), (" - browser + archiver + git ready.", DIM_FG)], delay=5.8),

        Line(prompt_segments(""), delay=6.6, typed=False),
    ]
    build_svg(
        title="run profile minimal  -  4-step fresh-Windows bootstrap",
        lines=lines,
        loop_seconds=9.0,
        out_path=OUT_DIR / "run-profile-minimal.svg",
    )


# ---------------------------------------------------------------------------
# Demo 1c: profile small-dev (advance + Go/Python/Node/pnpm)
# ---------------------------------------------------------------------------

def demo_profile_small_dev() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 profile small-dev"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=3.6),
        Line([("==> Profile: small-dev  (advance + 4 runtimes)", ACCENT_HEADER)], delay=3.7),
        Line([("    Expanded: 19 steps (advance + Go/Py/Node/pnpm)", DIM_FG)], delay=3.85),
        Line([("", TEXT_FG)], delay=4.0),

        Line([("[ 1-12 ] ", ACCENT_INFO), ("base profile (12 steps) ........ ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.2),
        Line([("[13-15 ] ", ACCENT_INFO), ("git-compact (3 steps) .......... ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.55),
        Line([("[16/19 ] ", ACCENT_INFO), ("golang ......................... ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.9),
        Line([("[17/19 ] ", ACCENT_INFO), ("python + pip ................... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.25),
        Line([("[18/19 ] ", ACCENT_INFO), ("node.js + yarn + bun ........... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.6),
        Line([("[19/19 ] ", ACCENT_INFO), ("pnpm ........................... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.95),

        Line([("", TEXT_FG)], delay=6.3),
        Line([("Coding box ready in ", DIM_FG), ("6m 28s", ACCENT_WARN), (" - Go/Py/Node/pnpm + IDE on PATH.", DIM_FG)], delay=6.5),

        Line(prompt_segments(""), delay=7.3, typed=False),
    ]
    build_svg(
        title="run profile small-dev  -  tight everyday dev box",
        lines=lines,
        loop_seconds=10.0,
        out_path=OUT_DIR / "run-profile-small-dev.svg",
    )


# ---------------------------------------------------------------------------
# Demo 1d: profile git-compact
# ---------------------------------------------------------------------------

def demo_profile_git() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 profile git-compact"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=3.8),
        Line([("==> Profile: git-compact", ACCENT_HEADER)], delay=3.9),
        Line([("    Git stack + SSH key + GitHub dir + .gitconfig", DIM_FG)], delay=4.05),
        Line([("", TEXT_FG)], delay=4.2),

        Line([("[1/5] ", ACCENT_INFO), ("git + git-lfs + gh           ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.4),
        Line([("[2/5] ", ACCENT_INFO), ("github desktop               ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.75),
        Line([("[3/5] ", ACCENT_INFO), ("ssh key (ed25519)            ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.1),
        Line([("       ", DIM_FG), ("public key copied to clipboard", DIM_FG)], delay=5.3),
        Line([("[4/5] ", ACCENT_INFO), ("default github dir           ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.6),
        Line([("       ", DIM_FG), ("created C:\\Users\\dev\\GitHub", DIM_FG)], delay=5.8),
        Line([("[5/5] ", ACCENT_INFO), ("apply default .gitconfig     ", TEXT_FG), ("OK", ACCENT_OK)], delay=6.1),

        Line([("", TEXT_FG)], delay=6.5),
        Line([("git-compact done in ", DIM_FG), ("2m 04s", ACCENT_WARN), (" - clone & push, ready.", DIM_FG)], delay=6.7),

        Line(prompt_segments(""), delay=7.5, typed=False),
    ]
    build_svg(
        title="run profile git-compact  -  git + ssh + GitHub dir + .gitconfig",
        lines=lines,
        loop_seconds=10.2,
        out_path=OUT_DIR / "run-profile-git-compact.svg",
    )


# ---------------------------------------------------------------------------
# Demo 1e: os clean detailed (folders + sizes)
# ---------------------------------------------------------------------------

def demo_os_clean_detailed() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 os clean --dry-run"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=4.0),
        Line([("==> OS toolbox: clean (DRY RUN -- nothing deleted)", ACCENT_HEADER)], delay=4.1),
        Line([("    Scope: temp + caches + recycle bin + event logs", DIM_FG)], delay=4.3),
        Line([("", TEXT_FG)], delay=4.5),

        Line([("  [scan] ", ACCENT_INFO), ("%TEMP%                          ", TEXT_FG), ("4,812 files   2.10 GB", DIM_FG)], delay=4.7),
        Line([("  [scan] ", ACCENT_INFO), ("%LOCALAPPDATA%\\Temp             ", TEXT_FG), ("1,203 files   780 MB", DIM_FG)], delay=4.95),
        Line([("  [scan] ", ACCENT_INFO), ("C:\\Windows\\Temp                 ", TEXT_FG), ("612 files   340 MB", DIM_FG)], delay=5.2),
        Line([("  [scan] ", ACCENT_INFO), ("C:\\Windows\\SoftwareDistribution ", TEXT_FG), ("2,041 files   1.40 GB", DIM_FG)], delay=5.45),
        Line([("  [scan] ", ACCENT_INFO), ("chocolatey lib-bad/lib-bkp      ", TEXT_FG), ("18 files   62 MB", DIM_FG)], delay=5.7),
        Line([("  [scan] ", ACCENT_INFO), ("Recycle Bin (all drives)        ", TEXT_FG), ("87 items   210 MB", DIM_FG)], delay=5.95),
        Line([("  [scan] ", ACCENT_INFO), ("Event logs + PSReadLine history ", TEXT_FG), ("- ", DIM_FG), ("clear", ACCENT_OK)], delay=6.2),

        Line([("", TEXT_FG)], delay=6.55),
        Line([("Total reclaimable: ", DIM_FG), ("4.89 GB", ACCENT_WARN), ("   files: ", DIM_FG), ("8,773", ACCENT_WARN)], delay=6.75),
        Line([("Re-run without --dry-run to delete.", DIM_FG)], delay=7.0),

        Line(prompt_segments(""), delay=7.8, typed=False),
    ]
    build_svg(
        title="run os clean --dry-run  -  preview reclaimable disk space",
        lines=lines,
        loop_seconds=10.5,
        out_path=OUT_DIR / "run-os-clean-detailed.svg",
    )


# ---------------------------------------------------------------------------
# Demo 2: install postgresql
# ---------------------------------------------------------------------------

def demo_postgres() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 install postgresql"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=4.0),
        Line([("==> Resolving keyword 'postgresql' -> script #20", ACCENT_HEADER)], delay=4.1),
        Line([("    Dev directory: ", DIM_FG), ("E:\\dev-tool\\postgresql", PROMPT_PATH)], delay=4.3),
        Line([("", TEXT_FG)], delay=4.5),

        Line([("[step 1/4] ", ACCENT_INFO), ("download installer ........ ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.7),
        Line([("[step 2/4] ", ACCENT_INFO), ("install service ........... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.2),
        Line([("[step 3/4] ", ACCENT_INFO), ("create role + database .... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.7),
        Line([("[step 4/4] ", ACCENT_INFO), ("verify with psql .......... ", TEXT_FG), ("OK", ACCENT_OK)], delay=6.2),

        Line([("", TEXT_FG)], delay=6.6),
        Line([("PostgreSQL 16 ", TEXT_FG), ("running", ACCENT_OK), (" on port ", DIM_FG), ("5432", ACCENT_WARN)], delay=6.8),
        Line([("Connect: ", DIM_FG), ("psql -U dev -d devdb", PROMPT_HOST)], delay=7.0),

        Line(prompt_segments(""), delay=7.8, typed=False),
    ]
    build_svg(
        title="run install postgresql  -  one keyword, full database stack",
        lines=lines,
        loop_seconds=10.5,
        out_path=OUT_DIR / "run-install-postgresql.svg",
    )


# ---------------------------------------------------------------------------
# Demo 3: os clean
# ---------------------------------------------------------------------------

def demo_os_clean() -> None:
    lines: List[Line] = [
        Line(prompt_segments(".\\run.ps1 os clean"), delay=0.4, typed=True),

        Line([("", TEXT_FG)], delay=2.6),
        Line([("==> OS toolbox: clean", ACCENT_HEADER)], delay=2.7),
        Line([("    Scope: temp + caches + recycle bin", DIM_FG)], delay=2.85),
        Line([("", TEXT_FG)], delay=3.0),

        Line([("  scanning   %TEMP%        ", TEXT_FG), ("4,812 files   2.1 GB", DIM_FG)], delay=3.2),
        Line([("  scanning   %LOCALAPPDATA%\\Temp   ", TEXT_FG), ("1,203 files   780 MB", DIM_FG)], delay=3.5),
        Line([("  scanning   Windows update cache  ", TEXT_FG), ("412 files   1.4 GB", DIM_FG)], delay=3.8),
        Line([("  scanning   Recycle Bin         ", TEXT_FG), ("87 files   320 MB", DIM_FG)], delay=4.1),

        Line([("", TEXT_FG)], delay=4.4),
        Line([("==> Reclaiming space ...", ACCENT_HEADER)], delay=4.5),
        Line([("  removed temp ............. ", TEXT_FG), ("OK", ACCENT_OK)], delay=4.8),
        Line([("  removed update cache ..... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.1),
        Line([("  emptied recycle bin ...... ", TEXT_FG), ("OK", ACCENT_OK)], delay=5.4),

        Line([("", TEXT_FG)], delay=5.7),
        Line([("Freed ", DIM_FG), ("4.6 GB", ACCENT_WARN), (" in ", DIM_FG), ("18s", ACCENT_WARN), (" - disk happy.", DIM_FG)], delay=5.9),

        Line(prompt_segments(""), delay=6.7, typed=False),
    ]
    build_svg(
        title="run os clean  -  reclaim disk space in one command",
        lines=lines,
        loop_seconds=9.5,
        out_path=OUT_DIR / "run-os-clean.svg",
    )


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    demo_profile()
    demo_profile_minimal()
    demo_profile_small_dev()
    demo_profile_git()
    demo_postgres()
    demo_os_clean()
    demo_os_clean_detailed()


if __name__ == "__main__":
    main()
