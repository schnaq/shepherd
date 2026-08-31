# ADR 0004: GitHub App + OAuth device flow, fine-grained PAT fallback

Status: Accepted · Date: 2026-08-31

## Context

An open-source desktop app cannot keep an OAuth client secret secret. GitHub's own guidance
and prior art ([research](../research/research-github-stack.md#1-authentication)): `gh` CLI
uses the secretless **device flow** with a public client ID; GitHub Desktop's bundled-secret
OAuth App pattern is a legacy wart. GitHub Apps beat OAuth Apps on fine-grained permissions
(`Pull requests: R/W`, `Contents: R`, `Checks: R`) and short-lived, refreshable user tokens.

## Decision

- Register a **GitHub App** for Shepherd (one app serves all users; its client ID is public
  and lives in the repo). Enable **device flow** as the primary sign-in.
- Offer a **fine-grained personal access token** field as fallback (SSO orgs, GHES, users who
  prefer it). Required PAT permission: `Pull requests: Read & write` (+ auto `Metadata`).
- Tokens (access + refresh + expiry, keyed by account login) are stored **only in the macOS
  Keychain** and are deleted on sign-out. Never in UserDefaults, files, or the database.
- Upgrade path: Authorization Code + PKCE loopback flow (GitHub supports it since mid-2025)
  can replace device flow later for a browser-auto-return UX without changing token storage.

## Consequences

- The maintainer must register the GitHub App once and put its client ID in
  `Shepherd/Support/AppConfig.swift`; forks can substitute their own ID.
- Auth code implements the device-flow poll loop (`interval`, `slow_down`) and transparent
  token refresh; PAT accounts skip refresh.
- Multiple accounts are possible later (Keychain entries are login-keyed) but v1 targets one.
