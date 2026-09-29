---
description: Review frontend code for accessibility, semantics and type safety
---

## Frontend review

When reviewing frontend code, apply these checks before anything else:

- **Accessibility** — semantic landmarks, labelled form controls, alt
  text on meaningful images, a sane focus order, and sufficient contrast.
- **Semantics** — correct elements over styled `<div>`s; no nested
  interactive elements; buttons for actions, links for navigation.
- **Type safety** — no `any`, no `@ts-ignore`, no `as` casts that merely
  silence a real error.
- **State flow** — state changes stem from user events, not timers or
  effects, unless a comment justifies the exception.

Report findings as a short list, most severe first, each with a
`file:line` reference and a one-line suggested fix.
