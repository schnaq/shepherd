# ADR 0002: Require macOS 26+ (Tahoe) on Apple Silicon

Status: Superseded in part by [ADR 0038](0038-macos-27-floor.md) (minimum version now macOS 27; Apple Silicon only still stands) · Date: 2026-08-31

## Context

Apple's Foundation Models framework — the basis for Shepherd's on-device summaries and triage
hints — requires macOS 26 and Apple Intelligence-capable hardware (Apple Silicon). Supporting
older systems would mean `#available` branches throughout the intelligence layer, a degraded
mode to design/test, and pre-macOS-26 SwiftUI workarounds.

## Decision

Minimum deployment target is **macOS 26.0, Apple Silicon only**. No Intel build.

## Consequences

- Foundation Models can be used unconditionally behind a single availability check (the model
  may still be unavailable on a given machine, e.g. Apple Intelligence disabled — the
  intelligence layer handles that at runtime, see ADR 0007).
- Newest SwiftUI APIs may be used freely; no fallback code paths.
- Users on older macOS are excluded — accepted for a new tool launching in 2026, and the
  audience (developers running coding agents) skews to current hardware.
- Revisit only if adoption data shows meaningful demand from macOS 15 users.
