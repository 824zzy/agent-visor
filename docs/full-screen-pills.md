# Full-Screen Pill Behavior

Status: Accepted
Last reviewed: 2026-07-16

## Purpose

The menu-bar pill strip must not cover a full-screen coding surface at rest. Full-screen use is an intentional focus mode, but Agent Visor navigation must remain available without leaving that Space.

The default behavior is therefore **hidden at rest, visible on intent**. Full-screen visibility is scoped to the configured pill screen; a full-screen window on another display does not hide the strip.

## Policies

Agent Visor exposes three user choices:

1. `Show on demand` is the default. Pills hide at rest and appear temporarily when the user reaches the top edge, holds the configured session-shortcut modifiers, or explicitly opens a menu-bar popover.
2. `Always hide` suppresses passive pointer and modifier peeks. Global direct-navigation shortcuts remain active, and an explicitly opened popover remains usable.
3. `Always show` keeps the strip visible above full-screen apps. This is an explicit opt-in because it can cover application content.

Existing persisted `media` and `never` behavior migrates to `Show on demand`. `Always show` must be selected explicitly under the current policy model so an upgrade cannot unexpectedly cover full-screen content.

## Reveal Intent

`Show on demand` recognizes these explicit signals:

- The pointer reaches the top 3 points of the configured screen. Once revealed, the full 40-point menu-bar band retains the peek so the user can move down and click a pill.
- The configured session-shortcut modifier family is held. This uses the same state that reveals the numbered pill keycaps.
- The More Sessions or Usage popover is open. The presenting strip remains available until the popover closes.

The pointer leaving the retention band hides the strip after 650 milliseconds. Releasing the shortcut modifiers hides it after 350 milliseconds. Returning before the deadline cancels the pending hide. These short grace periods prevent flicker without leaving the strip over content.

Session discovery, status changes, approvals, and completed turns do not reveal the strip automatically. Attention continues through the existing notification path rather than interrupting full-screen work.

## Rendering Contract

- Full-screen hiding is an opacity decision, not a layout decision. Agent Visor continues packing sessions and refreshing the rendered shortcut snapshot while the strip is hidden.
- Hidden pills do not accept global hit-test actions. Pointer movement and clicks continue to reach the full-screen application.
- Direct `1-9` session shortcuts and the `0` More Sessions shortcut remain functional while the strip is hidden.
- Reveal and hide animate opacity only. Pill size, order, side assignment, and hit regions do not move as part of the transition.
- The synthetic center notch indicator follows the same visibility decision as the pills.

## Detection

Agent Visor uses the target screen's actual full-screen window state. Native `AXFullScreen` evidence remains the canonical signal so a merely maximized window is not treated as a full-screen Space.

## Non-Goals

- Inferring user intent from media playback or display-sleep assertions.
- Revealing pills because a session becomes Ready, Working, or Needs attention.
- Moving the strip to another display when full-screen mode begins.
- Replacing macOS full-screen or menu-bar animation.

## Verification Matrix

Verify on the built-in display and an external display:

- normal windowed app;
- full-screen Codex with the strip at rest;
- top-edge reveal and delayed pointer exit;
- configured modifiers held and released;
- direct `1-9` navigation while initially hidden;
- `0` opening and closing More Sessions while initially hidden;
- all three settings;
- full-screen app on a display other than the configured pill screen;
- rapid Space and application switching.
