# Stack for iPhone

Stack has five places to work. Jobs is a deck for making a decision, Applications is a list for returning to a role, Network holds people and profile work, Resume holds documents, and Prep opens on a question. Each uses the same title, account avatar (the user's initials on the brand gradient) and bottom navigation. The shape of the content tells you where you are.

## Layout and hierarchy

- Start a tab with its name and a compact account button. Put the user's work immediately below it. Keep visited tabs mounted so a draft, deck position or recording review survives a round trip.
- Use a neutral canvas. Give a document, a group of related rows or the next practice question a raised surface. Use whitespace between sections and dividers inside lists. Reserve job photography for the deck and the Stack mark for identity.
- Put the frequent decision on the screen. Use a contextual menu for setup and occasional management. Put consequential approvals next to the material being approved. Keep the close action reachable while a sheet scrolls.
- Keep the existing system file picker, listing browser, permission dialogs and media playback controls. Give people a clear return to the item they came from.

## SwiftUI building blocks

| Element | Implementation |
| --- | --- |
| Page | Use `CollectionPage` for Applications, Network and Resume. Its pinned heading measures the remaining viewport so the empty or featured content can use its height. Use `Page` for other scrolling content with 20-point horizontal margins. Let long titles, prompts and field values wrap. |
| Tab title | `ScreenHeader` uses the system large title and a separate account action. Header accessories use `HeaderIconButton(systemName:label:action:)` or `HeaderMenu(_:label:content:)`, or `HeaderIcon(_:label:)` as a custom `Menu` label: one 17-point semibold symbol in a 36-point raised circle with a hairline, 44-point hit area, press scale. |
| Sheet | `SheetPage` pins the title and close control above its scroll view. Use its Back label for a preceding pane, and its close callback when a feature must save or confirm first. |
| Surface | `Card` uses 16-point interior padding, a 20-point continuous corner and a very soft light-mode shadow (`elevated: false` or `.stackElevation(false)` to remove; dark mode is flat). One surface can hold a group. Radii come from `Radius`: card 20, control and field 14, button 16. |
| Action | `StackButton` provides a 52-point primary button and a quieter secondary button. Keep a 44-point interaction area on compact controls. |
| Selection | Use a checkmark, selected trait, text or icon change alongside color. Use a native menu for a long single-choice list and a visible selector for peer destinations. |
| Text | Use system text styles for titles, headings, body and detail. Give form labels and long facts room at accessibility sizes. |
| People | `Avatar(name:)` or `Avatar(initials:seed:)` picks one of six soft tints from the name (`Palette.tint(for:)`); the old `Avatar(initials:)` keeps one tint. |
| State | `StatusPill(text:tone:)` with tones neutral, accent, success, warning, danger. One pill per row at most. |
| Lists | `SectionHeader(title:)` (footnote semibold, muted, sentence case, optional trailing control) heads a group. `SectionLabel` is the same without a trailing control. |
| Loading | `SkeletonBlock` and `SkeletonRow` hold the shape of loading content with a shimmer that stops under Reduce Motion. Prefer them to spinners. |
| Empty | `CollectionEmptyState` (symbol disc, title, optional subtitle, capsule action) sits slightly above center in the height it is given. `EmptyNote` is the inline version; `SymbolDisc` is the shared disc. |
| Fields | `StackField` uses an adaptive fill and visible focus border. Retain the keyboard dismissal action and the edited value after failure. |

## Color

| Use | Light | Dark |
| --- | --- | --- |
| Page | `#F5F6F8` | `#101216` |
| Surface | `#FFFFFF` | `#1C2027` |
| Raised control | `#FFFFFF` | `#252A33` |
| Primary text | `#191D25` | `#F1F3F7` |
| Secondary text | `#586170` | `#ADB5C4` |
| Accent text and symbols | `#2256CB` | `#8CB1FF` |
| Primary button with white label | `#2256CB` | `#365FCA` |

Use `Brand` and `Palette` from the design directory. For an inverted ink control use `Palette.dark` with `Palette.onDark`. Reserve danger and success colors for corresponding states. Documents, photographs and branded authentication buttons keep their own artwork.

## Motion

Tab selection takes effect immediately. A filled symbol and tinted label mark the active destination above a system bar material. A typical stage change takes 240 ms. A reveal moves six points in 230 ms, with 25 ms between siblings for at most four intervals. Buttons have a quick press-in with a slight dim and a damped spring release (`.tap` style). Spring tokens live in `Motion`: `snappy` for layout and selection, `smooth` for content swaps, `bouncyPress` for small pops, `Motion.animation(_:reduce:)` for the reduced-motion `nil`. The selected tab symbol bounces once. Use haptics for selection and completion.

Launch shows the mark while the account restores. The app becomes available when its data is ready. Read `stackReduceMotion` to honor the system setting and the preview policy. Keep the debug Motion Lab connected to the production views and offline fixtures.

For a new flow, check slow loading, empty data, failed requests, cancellations and return navigation. For a visual change, review text size, appearance, touch targets, keyboard reach and animation on a physical iPhone. See the [route audit and device walkthrough](../docs/ios-ui/README.md).

## Copy

- Titles are one to four words. Add at most one short supporting sentence, and only when it changes what the person does next.
- No explanations of how the system works, no disclaimers or repeated reassurance in primary UI. Put rare detail behind an About row or a footnote at the bottom of a sheet.
- Sentence case everywhere. No trailing periods on labels, buttons, chips or one-line captions.
- Buttons are verbs: Save, Upload resume, Start practice.
- No debug strings, internal names or dataset credits in primary UI.
