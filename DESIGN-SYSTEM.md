# Verdikt Design System — "Marble & Ink"

The visual identity of an impartial court: near-monochrome, institutional, precise.
Neutrality is the brand — the site refuses tribal color the way the court refuses bias.
One accent (verdict amber) exists solely to mark finality, verdicts, and live state.

## Tokens

```css
:root {
  --bg: #0a0b0d;            /* obsidian — hued, never pure black */
  --bg-2: #0e0f12;          /* alternate full-bleed band */
  --surface: #121316;       /* card / panel */
  --surface-2: #17181c;     /* raised / hover */
  --border: rgba(233, 229, 220, 0.08);
  --border-2: rgba(233, 229, 220, 0.16);
  --ink: #e9e5dc;           /* bone — primary text, primary buttons */
  --muted: #9b988f;         /* secondary text */
  --faint: #6b6962;         /* tertiary, labels */
  --amber: #e8b931;         /* VERDICT accent: finality, live, rulings ONLY */
  --amber-ink: #f0cd66;     /* readable amber on dark */
  --amber-dim: rgba(232, 185, 49, 0.12);
  --live: #4ade80;          /* pulsing live dot only */
  color-scheme: dark;
}
```

Rules: the neutral scale carries ~95% of every page. Amber appears on at most
~5% of any viewport — verdict pills, the live dot ring, one signature stat or
hairline per page. Never amber body text, never amber section backgrounds.

## Type

- **Display:** Cabinet Grotesk 700/800 — `https://api.fontshare.com/v2/css?f[]=cabinet-grotesk@500,700,800`
- **Body:** Switzer 400/500/600 — `https://api.fontshare.com/v2/css?f[]=switzer@400,500,600`
- **Mono:** JetBrains Mono 400/500/600 (Google Fonts) — addresses, amounts, IDs, code, eyebrows. Always `font-variant-numeric: tabular-nums`.

Scale (desktop targets, clamp on all display sizes):
- display-xl stat: clamp(72px, 9vw, 116px), lh 0.95, tracking -0.04em
- h1: clamp(44px, 6vw, 76px), lh 1.02, tracking -0.035em, weight 800
- h2: clamp(30px, 3.6vw, 44px), lh 1.1, tracking -0.025em
- h3: 20px, tracking -0.01em
- body: 16px / 1.6; small 14px; eyebrow 12px mono uppercase +0.14em

## Components

- **Buttons:** primary = bone fill (`--ink`) on dark text, hover translateY(-1px) +
  soft shadow; ghost = transparent + `--border-2` border. Radius 8px. No gradients.
- **Verdict pills** (one system everywhere): PAYEE = amber fill on dark text;
  PAYER = bone outline; SPLIT = amber outline + amber text; UNDECIDABLE = faint
  grey outline. 999px radius, 12px mono uppercase.
- **Live dot:** `--live` green solid dot + CSS ping ring (enabled, 2.4s). Pair
  with mono caption "Live · Somnia Shannon".
- **Cards:** `--surface`, 1px `--border`, radius 10–12px, border brightens to
  `--border-2` on hover. No drop shadows except modals.
- **Tables:** mono numerals right-aligned, eyebrow headers, divide-y hairlines,
  row hover = surface-2 tint.
- **Stats:** one display-xl signature stat per page max; secondary stats
  clamp(34px, 4vw, 56px). Count-up on first reveal only.
- **Atmosphere:** one warm radial glow (bone at 3–4% opacity) behind the hero;
  optional ultra-faint amber radial behind the signature stat. NO dot grids,
  NO violet auras, NO gradient meshes.
- **Focus:** `box-shadow: 0 0 0 2px var(--bg), 0 0 0 3.5px var(--amber)` on
  :focus-visible, site-wide. `prefers-reduced-motion` honored.

## Section rhythm

Alternate full-bleed (on `--bg`/`--bg-2`) and contained sections separated by
space (96–128px), not border stacks. One asymmetric feature section per page.
Never four equal-weight cards as a hero moment.

## Voice

No superlatives ("revolutionary", "seamless", "next-generation"). Numbers anchor
claims. Eyebrows are technical labels ("determinism · 12-case benchmark"), not
marketing. No emoji anywhere.

## Honest-data laws (non-negotiable)

Every metric is real: 92% accuracy (11/12 benchmark), 100% byte-identical
(12/12), 0 successful injections, 230 tests, live `rulingsCount` read from the
registry (fallback = last verified real value), real STT amounts, real
addresses linked to the explorer. Consensus renders UNANIMOUS/byte-identical —
never an invented split vote. Empty states are real states.
