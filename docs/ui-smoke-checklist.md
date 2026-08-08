# SwiftUI UI Smoke Checklist

Use this checklist for changes to layouts, navigation, sheets, forms, async
content, or keyboard behavior. Record only what was actually tested.

Test on one small and one large iPhone viewport when layout is affected.

## First-Entry Regression

- [ ] Kill the app, relaunch, and enter the changed screen for the first time.
- [ ] Do not tap or type for 5 seconds; layout is already correct and stable.
- [ ] Capture the first-entry state before interacting.
- [ ] Type one character; the layout does not suddenly repair or resize.
- [ ] Clear the character; the original correct layout remains.

## Lifecycle

- [ ] First presentation is correct.
- [ ] Navigate back and reopen; content and layout match first presentation.
- [ ] Background and foreground the app; no duplicate refresh or stale overlay.
- [ ] Present and dismiss each changed sheet; state is cleared or preserved as intended.
- [ ] Quickly switch between two items or rooms; state does not leak across identities.

## Data States

- [ ] Unresolved or initial loading state.
- [ ] Empty state.
- [ ] Error state and retry.
- [ ] Populated state.
- [ ] Partial or paginated state, including loading the next page.
- [ ] Long or slow-loading images do not change the container width.

## Input And Keyboard

- [ ] Before typing.
- [ ] After typing one character.
- [ ] After clearing all input.
- [ ] Keyboard shown and hidden.
- [ ] Focus gained and lost.
- [ ] Submit, failure, and retry preserve or clear input intentionally.

## Layout

- [ ] Small iPhone viewport.
- [ ] Large iPhone viewport.
- [ ] Long Chinese text.
- [ ] Long English text and one long unbroken token.
- [ ] Dynamic Type when the changed UI contains important text or controls.
- [ ] Safe area, navigation bar, keyboard, and custom tab bar do not overlap content.
- [ ] No horizontal scrolling unless the design explicitly requires it.
- [ ] Images stay inside the parent container and preserve the intended aspect ratio.

## State Consistency

- [ ] No layout shift after an unrelated interaction.
- [ ] No stale selection, error, toast, or draft after sheet dismissal.
- [ ] No duplicate network request after re-entry or foregrounding.
- [ ] No duplicate Realtime subscription or duplicated message.
- [ ] Loading and error states have one visible owner.
- [ ] The screen never becomes correct only after typing, scrolling, or rotating.

## Evidence

Record:

- Build/commit tested:
- Device or simulator and OS:
- Account/data fixture:
- Scenarios skipped and reason:
- Screenshots or screen recording:

Do not report visual verification as passed when only build or unit tests ran.
