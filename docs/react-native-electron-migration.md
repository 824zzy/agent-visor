# React Native and Electron migration

Agent Visor is moving to an Expo renderer, Electron desktop shell, and local TypeScript daemon.

The released Swift application remains production until macOS parity is complete.

## First stack slice

Requirements:

- Node 22
- npm 11.6.2

Install and run:

```sh
npx npm@11.6.2 install
npm run dev:desktop
```

The initial slice proved the local path with fixture sessions.

The daemon now reads live providers and streams stable session revisions. Its behavior is defined in [Live session daemon](live-session-daemon.md).

Release scripts still point only at the Swift application.

## Sessions browser

The Expo renderer now matches the released browser’s state sections, ranked search, keyboard cursor, source-first rows, and separate Chat actions.

Rows keep fixed owner and Chat columns at desktop and compact widths. Back retains the query, cursor, and viewport because Sessions stays mounted and hidden.

Electron activates only known owner applications. Exact session and window focus remains part of the native-services parity work.

Run the Electron accessibility and layout check with:

```sh
npm run test:sessions
```

Chat currently shows the retained-browser handoff surface. Conversation rendering and transport follow in the Chat parity work.

## Dependency status

`npm audit --omit=dev` reports no production dependency vulnerabilities.

The complete development audit reports ten moderate advisories through Expo’s unused iOS configuration path.

This slice uses Expo 57 for web only. Review those transitive advisories again before production packaging.

## Packages

- `packages/protocol`: Zod wire schemas and shared TypeScript types.
- `packages/server`: live provider state, hook intake, and local WebSocket delivery.
- `packages/app`: Expo and React Native Web Sessions renderer.
- `packages/desktop`: Electron lifecycle and daemon startup.

## Native helper

A narrow signed Swift helper keeps Accessibility, menu-bar geometry, session pills, and exact focus operations.

Its socket, validation, and signing contract is defined in [Native macOS helper](native-helper.md).

Paseo source informed the system shape, but no Paseo source code is included.
