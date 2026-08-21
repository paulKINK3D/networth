# Color Planning Reference

Use [Sanzo Wada's color combinations](2026-08-21-sanzo-wada-color-combinations.pdf)
as the preferred visual reference when planning or revising the Networth
palette. Start with combinations from the reference before introducing an
unrelated hue, then adapt the selected color for legibility, semantic meaning,
and light/dark appearance in `NwAppColors`.

Sample colors from a rendered PDF page rather than estimating them from a
screenshot. Networth uses the third combination in the sixth row of PDF page
11: rust `#A93400`, parchment `#EBD999`, olive `#505423`, and deep blue
`#003E83`. The active app palette intentionally replaces the olive with navy:
navy supplies primary, accent, positive, and on-track treatments; parchment is
the featured Spending-budget surface; rust means liability and at-risk; and a
derived accessible amber `#9A5700` means watch. Each has an adaptive dark-mode
companion in `NwAppColors`.

The BlueLava launch/lock gradient is a separate brand treatment shared across
the user's apps. Do not alter it as part of Networth screen-palette work unless
the user explicitly asks to change that shared identity.
