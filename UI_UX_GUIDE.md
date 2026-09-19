# UI/UX Guide — Not Looking Vibecoded

Everyday Buddy is a "lives on your laptop, trusted with your shell" kind of app. If the phone dashboard looks like a generic AI-generated demo, that undercuts the trust the product is actually asking for. This file exists so the UI doesn't undercut the engineering.

It's based on current (2026) design criticism of AI-generated interfaces — what gives them away, and why. Read this before touching the phone app or the web dashboard. See `DESIGN.md` for the actual enforced rules your AI coding agent should follow every session.

## Why this happens (so the rules make sense)

A coding agent generating UI isn't making design decisions — it's predicting what "modern UI" statistically looks like based on training data. It gives you the *average* of everything it's seen, not a specific point of view for your product. One independent audit ran 1,590 publicly shown app landing pages through an automated pattern checker: **22% triggered heavy "AI slop" signals, 32% triggered a couple, and only 46% came back clean.** The most common single tell was a permanently-on dark theme, followed by decorative gradient backgrounds and identical icon-card grids. That's the baseline you're trying not to blend into.

## The recognizable tells

### Typography
- **Inter for everything**, especially a centered hero headline — has become the default the way Times New Roman is the default for "didn't think about it." Not a bad typeface, just an invisible choice unless you make it on purpose.
- The same font pairing over and over: a geometric sans body font with a serif-italic word thrown in as "the accent."

### Color
- **The purple-to-indigo gradient.** Specifically the lavender-leaning shade that shows up everywhere a model is asked for something that feels "modern and technical." It's not a brand decision, it's an average of what Notion/Linear/Vercel-style products looked like in training data.
- **Permanent dark mode as the unquestioned default**, often with body text that fails basic contrast requirements against the dark background.
- **Decorative glow/blur effects** (aurora backgrounds, radial light bloom behind a hero) that don't respond to any user action or communicate any state — pure decoration competing with content.
- **Several saturated colors fighting for attention at once**, with no single dominant color and no clear accent.

### Layout
- **Everything wrapped in a card, then that card wrapped in another card.** Nesting three or four levels deep until nothing reads as more important than anything else.
- **A colored vertical stripe on the left edge of every card**, cycling through colors with no logic — described by more than one designer as "the em-dash of AI-generated UI": once you notice it, you can't stop seeing it.
- **Identical feature cards** — icon on top, headline, one line of body text, repeated three or four times with no visual variation.
- **Emoji used as icons, bullet points, or nav items** instead of a real icon system — because a real icon system requires a decision about meaning and weight, and an emoji doesn't.
- **Status dots that don't map to any actual state** — decoration pretending to be data.
- **A badge sitting right above a centered hero headline**, on default sans-serif, as the go-to "SaaS landing page" template.

### The structural tell underneath all of it
The AI-generated look isn't really any single pattern — it's the *absence of decisions*. A human-designed screen makes specific, deliberate choices about what to emphasize, what to leave out, and where to break the default grid. A generated screen applies the same safe default everywhere because the safe default is what the model has seen the most of. The fix is never "more polish" on the AI's first draft — it's making the small opinionated choices the AI didn't.

## Do

- **Pick one dominant color, one accent, and one neutral** — and actually hold that line across every screen. Visual hierarchy comes from restraint, not from adding more colors.
- **Choose a typeface on purpose, and write down why.** It doesn't have to be exotic — it has to be a decision, not a default.
- **Pick one layout primitive and repeat it** rather than mixing card grids, stat banners, numbered steps, and icon lists on the same screen. Consistency reads as intentional; variety-for-its-own-sake reads as generated.
- **Design real empty, loading, and error states** for every screen — an AI-generated interface optimizes for the happy path, so a raw error string or a blank first-run screen is itself a tell that no one looked past the demo case.
- **Use whitespace and typography for grouping** before reaching for a card/border. Reserve cards for things that are genuinely their own actionable, boundable object (a task, a device) — not every paragraph of text.
- **Give every status indicator a defined meaning**, documented somewhere the user can find it. If a dot needs an explanation, use a text label instead.
- **Write your palette, type system, and layout primitive down once** — in `DESIGN.md` — so your coding agent reads the same rules every session instead of re-deciding (and re-drifting toward the defaults) each time.

## Don't

- Don't accept the framework/library's out-of-the-box component styling unmodified and ship it — a small number of customized primitives (button radius, focus states, elevation) goes a long way and costs little.
- Don't use a purple-to-blue gradient as the "innovative tech product" signal by default — earn it as a deliberate brand choice, or skip it.
- Don't add glow/blur/aurora effects that don't respond to interaction or state.
- Don't nest cards inside cards inside cards. If you're three levels deep, something should become plain content instead.
- Don't put a colored left border on every card as a generic "this is styled" signal.
- Don't use emoji as your icon system, navigation, or bullet replacement in the actual product UI (fine in occasional in-app copy/notification text where tone matters — not fine as a substitute for real icons).
- Don't scatter status dots as decoration. If nothing is actually changing state, remove the dot.
- Don't let every dashboard screen be "sidebar + card grid, different data" — for an app this specific (voice control, screen preview, proximity status, task log), the layout should look like it was built for *these* screens, not retrofitted from a generic admin template.
- Don't ship the first thing the coding agent generates without running it against this file and `DESIGN.md` — treat this like a lint pass, not a suggestion.

## Applying this specifically to Everyday Buddy's screens

- **Pairing screen:** this is a trust moment (the user is about to grant full remote control) — it should look deliberate and secure, not like a generic onboarding template. No decorative gradients competing with the QR code/token entry.
- **Chat/voice UI:** resist the urge to add a glow effect around the "listening" state — use a real, purposeful animation tied to actual audio level or state, not decoration.
- **Task dashboard:** status indicators here are load-bearing (task running/done/failed) — this is exactly the place where a "status dot" needs a real, documented meaning, not decoration.
- **Proximity indicator (near/far):** this is safety-relevant information (it tells the user what the app can currently see/do) — make it unambiguous, not a subtle colored dot easy to miss.
- **Screen/webcam preview:** keep the chrome around the video feed minimal and functional — this is not a place for card-in-card nesting or gradient framing.

## Self-audit checklist before you call a screen done

Run this against every screen before it ships, the same way you'd run a linter:

- [ ] Is this the same layout shape (sidebar + card grid) as every other screen, or was it actually designed for this task?
- [ ] Could I remove a card wrapper here and use whitespace instead?
- [ ] Does every colored dot/badge map to a real, documented state?
- [ ] Is there a purple-to-indigo gradient anywhere I didn't deliberately choose?
- [ ] Did I design the empty state and the error state, or only the happy path?
- [ ] Would this screen look the same if I swapped it into a completely different app? (If yes, it's not designed for this product yet.)

## Sources

Findings above are synthesized from current (2026) design-criticism writing on AI-generated interfaces, including an independent 16-pattern audit of publicly shown app landing pages, and several practitioner write-ups on recognizable "vibe-coded" UI tells and their fixes. No content is quoted verbatim from any source.
