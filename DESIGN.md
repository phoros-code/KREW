# DESIGN.md

This is the design contract your AI coding agent reads before generating or editing any UI in this repo (phone app, web dashboard). Its whole job is to stop the defaults described in `UI_UX_GUIDE.md` from leaking in every session. Pair it with `CLAUDE.md`.

**Everything in the "Your choices" section below is a placeholder.** The entire value of this file comes from making these choices deliberately, once, rather than letting each generation session re-decide (and drift toward the generic default) on its own. Fill them in before Phase 3, and keep this file as the single source of truth after that — if you change a color or a font, change it here first.

---

## Your choices

*(Replace every value below. The ones shown are a reasonable non-default starting point — not a recommendation to leave unexamined.)*

**Palette**
- Base/neutral (70%): `#12131A` (near-black warm charcoal) / `#F5F4F0` (warm off-white, light mode)
- Primary/dominant: `#1E5F4A` (deep teal-green) — *not* the default purple-indigo
- Accent (10%, used sparingly): `#E8A33D` (warm amber) — for the one or two things per screen that should actually draw the eye
- Status colors (documented meaning required — see "Status meaning table" below): success `#3A8B5C`, warning `#D9932A`, error `#C4453D`

**Typography**
- Headline/display: Space Grotesk (geometric, technical without being generic; chosen for the "trusted console" feel)
- Body: IBM Plex Sans (humanist, distinct from the headline; readable at small sizes for logs)
- Monospace (for logs, tokens, command output): JetBrains Mono

**Spacing scale**
- Base unit: 4px. Scale: 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64. Don't invent arbitrary values outside this scale.

**Corner radius**
- Interactive (buttons, inputs): 8px. Containers: 12px. Don't mix five different radii across the app.

**One layout primitive**
- "Console column": every screen is a single column — a 56px status header (proximity + connection + task state), a scrollable content region, and (where input exists) a fixed bottom command bar. No sidebars, no card grids. Screens differ by what's in the content region (pairing form, chat log, task rows, video preview), never by layout shape.

---

## Status meaning table

Every status dot/badge in this app must have an entry here. If it's not in this table, it doesn't ship.

| Indicator | Color | Meaning | Where it appears |
|---|---|---|---|
| task queued | warning `#D9932A` | Command accepted, waiting to run | task list, chat |
| task running | primary `#1E5F4A` | Agent actively working | task list, chat, status header |
| task done | success `#3A8B5C` | Completed with a result | task list, chat |
| task failed | error `#C4453D` | Failed, see error text | task list, chat |
| proximity NEAR | success `#3A8B5C` + text label "NEAR" | Full control available | status header (always visible) |
| proximity FAR | warning `#D9932A` + text label "FAR" | Notifications only, commands blocked | status header (always visible) |
| connection offline | error `#C4453D` + text label | No route to laptop | status header |
| connection online | success `#3A8B5C` + text label "ONLINE" | Route to laptop alive | status header |
| connection connecting | warning `#D9932A` + text label | Opening live stream | status header |
| header task summary | primary `#1E5F4A` + count text ("N RUNNING" / "IDLE") | N tasks active vs idle | status header |
| listening | accent `#E8A33D` pulsing with audio level | Mic recording after wake word | chat/voice UI |

---

## Hard rules (checked every session)

Your coding agent should treat these as lint failures, not suggestions:

- [ ] No purple-to-indigo/blue gradient anywhere unless it's the palette chosen above
- [ ] No Inter font unless explicitly chosen above
- [ ] No decorative glow/blur/aurora effects that don't respond to real state or interaction
- [ ] No card nested inside a card inside a card — two levels max
- [ ] No colored left-border stripe used as a generic "this is styled" signal
- [ ] No emoji used as icons, nav items, or bullet replacements in product UI
- [ ] No status dot without a matching row in the Status meaning table above
- [ ] Every screen has a designed empty state and error state, not just the happy path
- [ ] Corner radius and spacing come from the scales above, not arbitrary values
- [ ] Before marking any screen done, run it against `UI_UX_GUIDE.md`'s self-audit checklist

## How to use this with your coding agent

Reference this file explicitly in UI-related prompts, e.g.:

> "Build the pairing screen per `DESIGN.md` and `UI_UX_GUIDE.md`. Use the palette and type choices from `DESIGN.md` exactly — don't introduce a gradient or font not listed there. Design the empty/error states, not just the happy path."

If the agent proposes a new color, font, or layout pattern mid-session, the answer is: update `DESIGN.md` first, then build — never the other way around.
