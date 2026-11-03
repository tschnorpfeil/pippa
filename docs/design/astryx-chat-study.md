# Astryx chat study: what Pippa's conversation can borrow

Astryx is Meta's React design system (`@astryxdesign/core`). Pippa is SwiftUI, so this study takes only the visual
language: radii, spacing, surface contrast, type, state changes and motion. No code is ported.

**Sources.** The Chat pages at <https://astryx.atmeta.com/components/ChatComposer> and siblings, `@astryxdesign/core`
v0.7.5, read on 2026-10-31. The numbers below are computed styles measured in the docs' live demos (dark theme), not
values guessed from screenshots. They were then checked against the MIT-licensed source at
<https://github.com/meta/astryx> (`packages/core/src/Chat/*.tsx`, `packages/core/src/theme/tokens.stylex.ts`); see
[What the source adds](#what-the-source-adds). Astryx builds its neutrals from white/black at low alpha, so its light
theme mirrors the dark values; Pippa's `Theme.fill*` tokens already work the same way.

**Baseline.** Pippa as on `release/0.3.18`. The thought line (twelve-dot `DotPulseView`, phase note, reasoning
disclosure, step chips with durations, the folded work receipt) stays the basis. Astryx only tunes how it looks.

Status: items 1–5 of [Priorities](#priorities) are implemented (see [Implemented](#implemented)); the rest wait
for a pick.

## What Astryx does, component by component

### Chat Composer (with Drawer, Input, Token Element)

- **Shape.** One rounded body, radius **28 px**, padding **12 px**, gap **8 px** between rows. Input on top, a footer
  row underneath: optional actions start-aligned (model picker, settings), mic and send end-aligned.
- **Surface.** Raised by default: no outer border, but a two-step shadow (`0 2 4 / 25 %`, `0 4 8 / 40 %` black) plus a
  1 px *inset* white hairline at 8 %. Body `#1B1B1B` on a slightly darker page. A flat variant swaps the shadow for a
  text-field border with rest, hover and focus states.
- **Type.** Input 14/22, placeholder in the muted grey (`#9E9E9E`).
- **Drawer.** Attachments and context sit in a drawer *behind* the body: top corners 28 px, a step lighter (`#262626`),
  padding `12 16 40`, so its lower 28 px tuck under the body. With a count it collapses to a badge ("6 Items") and shows
  a small grab bar.
- **Tokens.** File/context chips: 24 px high, radius **6 px**, `white 10 %`, 12 px text, padding 0 8, trailing ×.
- **Status.** Error or warning text sits directly above or below the body, not inside it.
- **Motion.** Shadow and border transitions 125 ms, `cubic-bezier(0.24, 1, 0.4, 1)` (fast out, soft landing).

### Chat Send Button

- One **32 px circle** that changes role: **Send** is primary (inverted ink: near-white disc, dark arrow), **Stop** is
  secondary (`white 10 %` disc, white square). Same place, same size.
- Disabled = **opacity 0.5**; it enables as soon as the input has content.
- Icon only; the accessible name stays "Send"/"Stop". Colour transition 125 ms, same curve.

### Chat Dictation Button

- Ghost 32 px icon button directly left of Send.
- Idle: microphone. Listening: the icon is **replaced by animated frequency bars** that follow the real input level.
- Interim transcript appears as ghost text inside the input itself.

### Chat Layout (with Scroll Button)

- Messages in normal flow, pushed to the bottom while the list is short. Composer docked at the bottom in a
  "frosted" layer: `backdrop-filter: blur(12px)` masked by a 36 px gradient so the blur fades in.
- Density sets message gap and bubble padding together: compact **8** (bubble radius 12), balanced **16**, spacious
  **24** (bubble padding 16 × 20).
- **Scroll button.** 32 px circle, composer surface, shadow `0 2 4 / 35 %`, `0 4 12 / 50 %`, inset hairline 12 %.
  Appears (opacity + transform, 165 ms) once the user scrolls up; **expands into a labelled pill** ("New messages",
  "3 unread replies") when something new arrives.

### Chat Message (with Bubble, List, Metadata)

- **User:** bubble, `white 10 %`, radius **28 px**, padding 12 × 16, 14/20 text, max width `max(80 %, 280 px)`.
- **Assistant:** "ghost" bubble: same padding and alignment, no background. Long answers read as plain text.
- **Groups:** consecutive bubbles 4 px apart; the corners facing each other drop to **6 px**
  (first `28 28 6 28`, middle `28 6 6 28`, last `28 6 28 28` on the sender's side).
- **Metadata:** one 12 px muted line *below* the message: time · status · model. On assistant messages the line can
  carry quiet icon actions (copy, retry, thumbs up/down).
- Message gap 16 px (balanced).

### Chat System Message

- Centered 12 px muted text, no background ("Alex joined", "Conversation marked as resolved").
- Divider variant for dates: hairline (`white 10 %`) · label with 12 px side padding · hairline.

### Chat Tokenized Text

- Inline badges inside message text for serialized tokens (`@person`, `#tag`, `/command`): pill, 20 px high, 12 px
  medium text, tinted by kind (blue people, red bugs, green features).

### Chat Tool Calls

- **No cards, no chips.** Each call is a flat row, 24 px pitch, everything 12 px muted grey.
- Row: **12 px status glyph** (pending = dim ring, running = spinner ring, done = green check-circle, error = red
  ×-circle) · tool name in monospace medium · target (path, command, query) · diff stats in green/red · **duration
  trailing** (`340ms`, `1.8s`).
- Several calls collapse under a header row: wrench icon · "3 tool calls" · chevron. Collapsed, the latest call stays
  visible.
- A row with a result expands in place; the detail is indented **22 px** (aligned with the text after the glyph) and
  sits in a code block, radius 10, darker than the page, 1 px hairline.
- Colour is reserved for state (green/red glyphs, diff numbers). Text never changes colour.

## What the source adds

The repository confirms the measurements and explains the reasoning behind several of them. These points change or
sharpen the recommendations below.

- **A separate chat radius.** `--radius-chat` (28 px) is its own token "so chat rounding can be themed
  independently": chat surfaces (bubbles, composer, drawer) are *intentionally rounder than cards in the same view*.
  The rest of the scale is small and regular: inner 4, element 8, container 12, page 28, full 9999.
- **Concentric radius.** Inside the composer, buttons take `max(8, outer radius − padding)`: 28 − 12 = 16, which makes
  the 32 px send button a circle *because of* the shell, not by its own rule.
- **Focus is elevation, not a ring.** The raised composer sits at `--shadow-low` and bumps to `--shadow-med` on hover
  and focus. The focus *ring* only appears for keyboard focus; clicking into the field adds none.
- **Motion tokens.** Defaults are fast **175 ms** (min 130, max 230), medium **410 ms**, slow **975 ms**.
  `--ease-standard` = `cubic-bezier(0.24, 1, 0.4, 1)` for arrivals and state changes; `--ease-exit` =
  `cubic-bezier(0.3, 0, 0.6, 0.6)` for things leaving. (The docs site runs a slightly faster theme, hence the 125 ms
  measured above.) Composer shadow uses fast; the scroll button's appear/expand (opacity, transform, `max-width`) uses
  fast-max; a tool-call row opens with a height reveal at medium; its chevron turns at fast.
- **Tool calls.** Pending and running both show a subtle spinner; complete and error swap in a semantic icon. With
  several calls the collapsed header *is* the latest call plus the count, not a separate summary line. Duration shows
  only once complete.
- **Dictation bars.** Five bars, 2.5 px wide with 2 px gaps, 18 px tall at most, never below 8 % height, in the accent
  colour, blending toward the error colour when the input clips. Reduce Motion drops the transition to 0 s.
- **Send button.** Size `md` by default (an `sm` exists); Send is `primary` with `arrowUp`, Stop is `secondary` with
  `stop`, both from the icon registry, swappable per product.

## Mapping onto Pippa

Decision key: **adopt** = take as is, **adapt** = take the idea in Pippa's terms, **skip** = not for Pippa.

### Composer (`ConversationWorkspace.composer`, `ConversationWorkspace.swift:641`)

| Trait | Decision | Why |
|---|---|---|
| Radius 28, padding 12 | **Adapt**: radius 24 continuous, padding 10–12 | Pippa's window is 700 pt wide with 14.5 pt type; 28 reads as a pill at one line, 24 keeps it soft but still a field. |
| Raised: shadow + inset hairline, no border | **Adapt** | Replaces the 1 pt `chatBorder` outline. Follow the source: focus raises the shadow one step instead of drawing the current outer 1 pt `accent 0.4` stroke. Keep an accent ring only for keyboard focus (Full Keyboard Access). |
| Concentric inner radius | **Adopt** | Inner controls take outer radius − padding (24 − 8 = 16 → the 32 pt send circle). One rule instead of per-button radii. |
| Two rows: input, then footer with actions | **Adapt** | Input gets the full width; `+` (add files), mic and Send move to a footer row. Fixes the `+` sitting baseline-aligned left of a multi-line field. |
| Drawer behind the body for context | **Adapt** | `FrontAppChip`, `composerAttachments`, pending drops and `DictationStrip` currently stack loosely above the field (`VStack(spacing: 8)`). One drawer tucked under the body ties them to the message they belong to. |
| Collapsible drawer with count | **Skip for now** | Pippa rarely carries more than a few files; revisit if folders of files land here. |
| Status above/below the body | **Adopt** (already close) | Error and blocked text already sit under the composer; keep them outside the body. |
| Model/settings pickers in the footer | **Skip** | Pippa hides the model on purpose; the footer only holds attach, dictate, send. |
| 6 px token chips | **Skip** | Pippa's capsule file chips match its own chip family (`Chip`, `SourceChip`); a second chip shape would split it. |

### Send, stop, dictation

| Trait | Decision | Why |
|---|---|---|
| One 32 pt circle, Send ↔ Stop | **Adopt** | Today Send is a `.pippa(.primary)` capsule (32 pt label + 2 × 16 pt padding ≈ 64 × 34) and Stop is a different-width text capsule "Stop Answering". One circle that swaps its icon stops the footer from jumping. ⌘. and the help text stay. |
| Primary = inverted ink | **Skip** | Pippa's primary is the accent blue; keep it. Only the shape changes. |
| Stop = secondary fill + square | **Adopt** | `Theme.fill2` disc with `stop.fill`. |
| Disabled = 0.5 | **Adopt** (close) | `PippaButtonStyle` uses 0.4; 0.5 on the circle reads better on the blue. |
| Mic as ghost button next to Send | **Adopt** (already there) | `DictationButton` is 28 × 32 ghost; align to 32 × 32. |
| Listening = level bars in the button | **Adapt** | Replace `mic.fill` with five accent bars (Astryx: 2.5 pt wide, 2 pt gaps, 18 pt tall, never below 8 %). `Dictation` publishes no level yet: it needs an RMS value computed in the existing audio tap (`App/Dictation.swift`, `installTap`), throttled to ~15 Hz like `DotPulseView`. Skip the clip-to-red blend. Reduce Motion: static bars. |
| Interim text as ghost text in the field | **Skip** | Pippa's strip with "⏎ inserts · esc discards" is clearer about what happens; it moves into the drawer instead. |

### Messages (`plainMessageView`, `ConversationWorkspace.swift:491`)

| Trait | Decision | Why |
|---|---|---|
| User bubble radius 28, padding 12 × 16 | **Adapt**: radius 20 continuous, padding 10 × 14 | Today 16 / 12 on all sides. Rounder and a little wider reads more like Astryx without becoming a pill on long messages. |
| User bubble fill `white 10 %` | **Skip** | `Theme.chatUser` is already a neutral step above the background in both modes. |
| Assistant as ghost (no bubble) | **Adopt** (already there) | Same choice; keep it. |
| Grouped corners (6 px inner) | **Skip** | Pippa merges a user's quick follow-ups into the queue (`queuedView`); consecutive user bubbles are rare. |
| Max width 80 % | **Adapt** | User bubbles use `Spacer(minLength: 60)`; on wide windows that lets a bubble run to ~640 pt. Cap at ~80 % of the content width. |
| Metadata line *below* | **Adapt** | Today a label sits *above* (`visibleLabel`, 11 pt ink3). Move time/"Stopped"/draft notes into one 11–12 pt line under the message. |
| Hover actions (copy, retry) | **Adapt** | Copy only lives in a context menu. A quiet copy (and "ask again") on hover under the newest answer helps discovery. Thumbs: **skip**, nothing to send them to. |
| Message gap 16 | **Adopt** (already there) | `VStack(spacing: 16)`. |
| Density levels | **Skip** | One surface, one density. |

### System notices and dividers

| Trait | Decision | Why |
|---|---|---|
| Divider: hairline · label · hairline | **Adopt** (already there) | `topicLine` and the skill divider match it. |
| Centered muted status text | **Adapt** | `.system` messages render left-aligned like an answer. Center them at `Fonts.hint`, ink3, so they read as notices, not as Pippa speaking. |
| Inline tokens in text (`@`, `#`, `/`) | **Skip** | Pippa has no mentions or slash commands in messages. Revisit if skills get a `/` trigger. |

### Thought line and tool steps (`ThoughtLineView.swift`, `DotPulseView.swift`)

The Prima-based design stays: one twelve-dot sign, the phase note, the reasoning disclosure, step durations, "N
earlier steps", the folded receipt. Astryx changes only the *weight* of the steps.

| Trait | Decision | Why |
|---|---|---|
| Flat rows, no chip | **Adapt** | `StepChip` is a 30 pt capsule with card fill, hairline, drop shadow and, once done, an `okTint` wash. Four of them stacked is the loudest thing on screen while the answer is the point. Keep the capsule but drop the shadow and the green wash; done = the check glyph only. (Full flattening into `StepRow`-style rows is the L option below.) |
| Status glyph per state | **Adapt** | Running steps show nothing extra today; done gets a check at the end. Move state to a fixed leading slot: running = small subtle spinner (Astryx uses the same spinner for pending and running), done = check, failed = `exclamationmark` in `need`. Same slot in `StepRow` in the receipt. The twelve-dot sign stays the one sign for the whole answer; the slot is per step. |
| Collapsed group = latest call + count | **Adapt** | "N earlier steps" already folds older chips. Astryx folds into the latest row itself; Pippa keeps four visible, which reads better for slow local steps. Keep, but align the wording and chevron. |
| Colour only for state | **Adopt** | Running text switches `ink` → `ink2` when done; keep the text one colour and let the glyph carry it. |
| Monospace tool names | **Skip** | Pippa says "Read the contract", not `read`. Everyday words are a product decision. |
| Target + duration trailing | **Adopt** (already there) | Durations landed in 0.3.18; keep them trailing, monospaced digits. |
| Group header "N tool calls ⌃" | **Adopt** (already there) | "N earlier steps ⌄" and the receipt summary do this. Align chevron size and rotation (8.5 pt, 180°) everywhere. |
| Result detail indented to the text | **Adopt** (already there) | Action receipt uses `padding(.leading, 21)`. |
| Code-block detail | **Skip** | Pippa's results are documents and cards, not terminal output. |
| Diff stats, node badges | **Skip** | No code edits, no sandboxes. |

### Layout, scroll button, header

| Trait | Decision | Why |
|---|---|---|
| Frosted blurred dock | **Skip** | The window is already a material (`ShellTokens.material`); a second live blur costs GPU on the MacBook Air for little gain. The existing 10/18 pt fade mask does the same job. |
| Scroll button: circle, shadow, inset hairline | **Adopt** (already there) | `JumpToLatestButton` matches almost exactly. |
| Scroll button expands with a label on new content | **Adapt** | It only turns accent today. While Pippa answers off-screen, widen it into "New answer ↓". |
| Appear motion 165 ms opacity + transform | **Adopt** (already there) | Uses `.smooth(0.25)` with scale + offset; fine. |
| Conversation header | **Skip** | Astryx has no chat header; `ConversationWindow` header stays. |

### Tokens (`Views/Theme.swift`)

| Trait | Decision | Why |
|---|---|---|
| Pure neutral greys | **Adapt** | Dark `chatCard` is `#232833`, blue-tinted, while `chatTint` (`#1B1B1D`) and `chatUser` (`#303033`) are neutral. Composer, step chips and receipts therefore look bluish against a neutral window. Make dark `chatCard` neutral (around `#262628`). Light mode is already neutral white. |
| Named motion curves | **Adopt** | Astryx uses one arrival curve, `cubic-bezier(0.24, 1, 0.4, 1)`, for every state change, and a separate exit curve. Pippa mixes `easeOut(0.15)`, `easeOut(0.3)` and springs. Add `Motion.quick = .timingCurve(0.24, 1, 0.4, 1, duration: 0.15)` for hover, press and colour changes and `Motion.exit = .timingCurve(0.3, 0, 0.6, 0.6, duration: 0.15)` for things leaving. Springs stay for layout and the shell. |
| Small regular radius scale + separate chat radius | **Adapt** | Pippa's views use 15 different corner radii (1.4 to 26; 8, 12, 14, 16 and 18 most often). Introduce `Radius.inner 4 / element 8 / container 12 / chat 20–24` and move views onto it as they are touched. Chat surfaces (composer, user bubble) stay rounder than cards, as in Astryx. |
| Elevation shadow pair | **Adopt** | A `raised` modifier (`shadowInk` 0.10 r1 y0.5 + 0.16 r8 y4, inset hairline) already exists ad hoc on `JumpToLatestButton`; name it and use it for the composer too. |
| Figtree, 14/20 type | **Skip** | Pippa uses SF with its own scaled sizes; 14.5/15 pt body suits macOS reading distance. |

## Before / after

| Element | Before (0.3.18) | After (proposed) |
|---|---|---|
| Composer body | radius 18, padding 8, `chatCard` + 1 pt `chatBorder`, focus = 1 pt accent 0.4 stroke | radius 24 continuous, padding 8–12, `raised` shadow + inset hairline, focus = shadow one step up (ring only for keyboard focus) |
| Corner radii | 15 different values across the views | `Radius` scale 4 / 8 / 12 + chat 20–24, adopted as views are touched |
| Composer rows | one row: `+` · field · mic · send | field full width; footer row: `+` … mic · send |
| Context above field | front-app chip, file chips, drops, dictation strip stacked loosely | one drawer tucked behind the body |
| Send | blue capsule ≈ 64 × 34 | blue 32 pt circle, `arrow.up` |
| Stop | text capsule "Stop Answering", other width | same circle, `fill2`, `stop.fill`; name in help/VoiceOver |
| Dictation (listening) | `mic.fill` in accent | level bars in the button |
| User bubble | radius 16, padding 12, up to full width − 60 | radius 20 continuous, padding 10 × 14, max ~80 % |
| Message meta | 11 pt label above | 11–12 pt line below; copy on hover for the newest answer |
| System notice | left-aligned hint text | centered hint text |
| Step chip | capsule, card fill, hairline, shadow, green wash when done, check at the end | capsule, card fill, hairline; state glyph in a fixed leading slot; no shadow, no wash |
| Scroll button on new content | turns accent | widens to "New answer ↓" |
| Dark `chatCard` | `#232833` (blue cast) | neutral, around `#262628` |
| Hover/press motion | mixed `easeOut(0.15)` and springs | `Motion.quick` for arrivals and state, `Motion.exit` for leaving |

## Priorities

Size: **S** ≈ one view, under an hour; **M** ≈ several views or a new component; **L** ≈ structural, needs snapshot
review across surfaces.

1. **S · Send/Stop as one 32 pt circle.** Biggest visible win per line changed; ends the footer jump between states.
2. **S · Composer surface.** Radius 24, `raised` shadow + inset hairline instead of the outline; focus lifts the
   shadow instead of drawing an accent stroke; inner controls follow the concentric radius.
3. **S · Neutral dark `chatCard`.** One token; removes the blue cast from composer, chips and receipts. Check every
   `chatCard` user in snapshots.
4. **S · Quieter step chips.** Drop shadow and green wash; state glyph in a fixed leading slot. Prima basis untouched.
5. **S · Scroll button label on new content.** "New answer ↓" while Pippa answers off-screen.
6. S · User bubble radius/padding/max width.
7. S · Centered system notices.
8. S · `Motion.quick` / `Motion.exit` curves for hover, press, appear and leave.
9. M · Two-row composer with footer actions.
10. M · Composer drawer for front app, files, drops and dictation.
11. M · Metadata line below messages with hover copy / ask again.
12. M · Dictation level bars (needs a level from the audio tap).
13. M · `Radius` scale with a separate chat radius; views move onto it as they are touched.
14. L · Full flattening of running steps into Astryx-style rows (chips become rows like `StepRow`). Only if 4 is not
    calm enough.

Recommended first batch: **1–5**. They are independent, each touches one or two files, and together they carry most of
the Astryx feel (round raised composer, one action circle, calm steps, neutral surfaces) without moving any layout.

## Implemented

Items 1–5, with these deviations from the text above:

- **Composer padding stays 8**, not 12, so the concentric rule gives the 32 pt send circle exactly (24 − 8 = 16).
- **No separate keyboard-focus ring.** SwiftUI cannot tell keyboard from pointer focus on a text field; the shadow
  lift and the caret mark focus for both.
- **The step state sits at the end of the chip, not the start.** The leading place already holds the step's picture,
  which shows a failed step; a second leading glyph would stack two circles. The end slot has a fixed width, so the
  chip keeps its size when the spinner turns into the check. Under Reduce Motion the spinner is a static ellipsis.
- **Motion:** only `Theme.quick` (the arrival curve, 150 ms) was added, for the send circle, the composer lift and the
  scroll button. `Motion.exit` and the rest of item 8 are still open.

## T3 Code adaptation (0.4.x chat window)

The 0.4 chat window (`Views/ChatView.swift`, split into `Sidebar.swift`, `Composer.swift` and `ContextPanel.swift`)
takes most of the remaining items, using T3 Code's desktop chat as the second reference for layout and density.

**Tokens (`Views/Theme.swift`).** `Radius` (inner 4, row 6, control 8, card 12, bubble 18, chat 20), `Space`
(2 to 32) and `Layout` (column 736, gutter 20, inspector 280, sidebar 248, card 560). Surfaces get `hairline`,
`topLight` (dark only), `rowHover`, `rowSelected` and `sendDisabled`; `chatInset` lost its blue cast and dark
`chatUser` is calmer. `Theme.quick`, `Theme.arrive` and `Theme.leave` are `nil` under Reduce Motion. The enum `Layout`
shadows SwiftUI's protocol inside the app module, so layouts conform to `SwiftUI.Layout`.

**Surfaces.** `View.raised(_:lifted:)` is the one raised surface: card colour, 1 pt inset hairline, top light in dark
mode, a soft shadow that deepens when lifted. The composer, result cards, receipts, file chips and the scroll button
use it. Hover is always `rowHover`, never a border colour as a fill. Result cards share `CardHeader` (22 pt tinted
symbol badge) and `CardRowButton` (inset rounded hover, pointing hand).

**Items done:** 6 (bubble 18 pt, 14 pt text, at most 78 % of the column), 8 (all three curves), 9 (two-row composer:
text on top, attach / AI badge / send below), 10 for files (a drawer tucked 16 pt behind the composer's top edge;
the front app and dictation are not in it), 11 (sources left, Copy and Ask Again right; always on the last answer,
on hover otherwise), 13, and 14 in a lighter form: the work line is one 28 pt row ("Worked for 18 s · 3 steps"),
expanded steps are flat 24 pt rows with a 14 pt state glyph.

**Scroll follow.** The transcript follows new words only while its end is in view. "In view" may turn off only while
the person scrolls (`onScrollPhaseChange`), so content growing under a programmatic scroll never unpins it. Scrolled
up, a 32 pt round button appears above the composer and widens to "New answer" while an answer comes in. A new
question always scrolls to the end.

**Sidebar.** "New Conversation ⌘N" as the first row; one 36 pt line per conversation with a 20 pt trailing slot
(spinner while that conversation answers, a dot for an answer that arrived while another conversation was open, a pin)
that turns into the row's menu on hover. Conversations can be switched while an answer runs; it keeps arriving in its
own conversation, and Stop only shows there.

**Not taken:** centered system notices (7) and dictation (12), as before.


## Chat layout follow-up (2026-11-03)

Implemented locally: a new chat window uses up to 1200 × 800 pt, bounded by the screen's visible area with room
around it. The right inspector starts closed unless the person previously chose to show it. Existing saved window
frames and explicit inspector preferences remain in force. The reading column stays capped at 736 pt so widening
the window does not turn answers into long lines.

Next priorities, based on the current implementation and reported use:

1. Validate the basic interactions with real Mail drags, file drops and keyboard input before further styling.
2. Keep work details collapsed and make the finished result easy to find; avoid presenting internal reasoning as
   the main content. The current work row already starts collapsed.
3. Show meaningful progress (what Pippa is reading or preparing), with Stop always reachable. Avoid an elapsed
   counter as the only feedback during a long wait.
4. Put the useful action on each result: open the file, reveal it in Finder, open the draft. Sources and changes
   remain available inline and in the optional inspector.
5. Keep the pill focused on quick access and drops; use the main window for reading and reviewing longer work.
6. Keep provider/model identifiers in settings or details; use everyday wording in the main chat.

References: [T3 Code thread interactions](https://github.com/pingdotgg/t3code/blob/main/docs/user/thread-sidebar.md),
[Apple sidebar guidance](https://developer.apple.com/design/human-interface-guidelines/sidebars), and
[Type to Siri](https://support.apple.com/en-gb/105020). These are interaction references; proposed Pippa changes
above are product judgments, not claims that the referenced apps implement every item identically.
