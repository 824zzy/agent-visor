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

The first slice uses fixture sessions. It proves the local path from Electron through Expo to the typed WebSocket daemon.

It does not read live providers or replace release scripts.

## Dependency status

`npm audit --omit=dev` reports no production dependency vulnerabilities.

The complete development audit reports ten moderate advisories through Expo’s unused iOS configuration path.

This slice uses Expo 57 for web only. Review those transitive advisories again before production packaging.

## Packages

- `packages/protocol`: Zod wire schemas and shared TypeScript types.
- `packages/server`: local WebSocket daemon and fixture snapshot.
- `packages/app`: Expo and React Native Web Sessions renderer.
- `packages/desktop`: Electron lifecycle and daemon startup.

## Native helper

A narrow signed Swift helper keeps Accessibility, menu-bar geometry, session pills, and exact focus operations.

Its socket, validation, and signing contract is defined in [Native macOS helper](native-helper.md).

Paseo source informed the system shape, but no Paseo source code is included.
