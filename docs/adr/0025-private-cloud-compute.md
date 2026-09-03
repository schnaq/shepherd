# ADR 0025: Private Cloud Compute as a tier between on-device and bring-your-own-key — parked, with the conditions that would unpark it

Status: Parked · Date: 2026-09-03

## Context

The Intelligence v2 plan (`docs/plans/apple-intelligence-v2.md`, §I) sketched a rung between tier 2
and tier 3 of [ADR 0007](0007-layered-intelligence.md): Apple's `PrivateCloudComputeLanguageModel`
behind the same `LanguageModelSession` call sites as the on-device model, giving a reviewer who
will not bring an API key a 32K context for the same requests. The plan said "verify the SDK
first", and this ADR records what the verification found on 2026-09-03 against Apple's developer
documentation, the WWDC26 sessions and Apple's Private Cloud Compute developer page.

What is confirmed:

- `PrivateCloudComputeLanguageModel` exists, conforms to a new `LanguageModel` protocol, has a
  32K context and a `reasoningLevel` of `.light` / `.moderate` / `.deep`. Its availability surface
  is `availability` with two unavailable reasons, `deviceNotEligible` and `systemNotReady`, and a
  `quotaUsage` with `isLimitReached` and `resetDate` but no published numbers.
- Both the protocol and the type are **macOS 27.0+**, currently in beta. The research notes said
  macOS 26.4; that was wrong. Shepherd's deployment target is macOS 26.0 (`project.yml`).
- The **no-cost entitlement** Apple documents is granted to developers enrolled in the App Store
  Small Business Program, for apps **distributed on the App Store** (TestFlight and ad hoc for
  testing). Apple's page names no path for a Developer-ID-signed app distributed directly, which
  is how Shepherd ships ([ADR 0010](0010-distribution-dmg-homebrew.md)).
- The request leaves the Mac. That is the point of the tier, and it is also why it cannot be a
  silent upgrade of tier 2.

What could not be confirmed: the hostnames the framework contacts (needed for the host list in
`CONTRIBUTING.md`), whether tool calling and guided generation are supported against the server
model as a stated capability rather than by inference from "existing session code works", and
the retention guarantees as restated for this API.

## Decision

**Not built now.** The rung stays in the plan as a design, not as work, until three things are
true at once:

1. Shepherd targets macOS 27 or later. The tier cannot exist behind an `#available` check on a
   26.0 app — the type is not in the SDK the app is built against, and a feature a reviewer can
   see in Settings but never use on their OS is a promise the app cannot keep.
2. Apple documents an entitlement path for apps distributed outside the App Store, or Shepherd
   ships through the App Store. Neither is on the roadmap; the second would be its own decision
   about sandboxing, the Keychain layout and the update channel ([ADR 0010](0010-distribution-dmg-homebrew.md)).
3. The framework documentation names the hosts, so the privacy contract in `CONTRIBUTING.md` can
   list them before the first request is made, as it does for every other host.

When those hold, the design below is what gets built, and it is recorded here so the decision
about *how* is not re-litigated with the decision about *whether*:

- **A rung, not a replacement.** `IntelligenceMode` gains a case between on-device and cloud;
  the router tries on-device first and Private Cloud Compute second, exactly as it tries the
  configured cloud endpoint today. The 8K pre-flight against the on-device tokenizer stays the
  first gate; the 32K budget is the second.
- **Attended surfaces only.** Drafts, "explain these lines", the delegation brief and "why is CI
  red?" may reach it, because each is one click by the reviewer on content they are looking at.
  Triage, thread digests, the Siri summary and anything in a sweep stay on-device only — ADR
  0007's rule that unattended work never leaves the Mac is not weakened by the request going to
  Apple rather than to a configured endpoint.
- **Reported, not implied.** The served-by line the cloud tier already shows says "Private Cloud
  Compute" for these answers, and the Settings copy says in one sentence that the request leaves
  the Mac and is not retained, with Apple's page linked.
- **Same reasoning budget rule as the 8K one.** `reasoningLevel` costs context; `.light` for
  drafts and explanations, `.moderate` for the CI diagnosis, never `.deep`, and the pre-flight
  counts the reasoning allowance against the 32K.
- **Quota is a state, not an error.** `quotaUsage.isLimitReached` shows as "available again
  at …" from `resetDate`, on the same line the cloud tier uses for a `Retry-After`.

## Consequences

- Nothing in the code changes. `IntelligenceMode` keeps its three cases; the host list is
  unchanged; the Settings tab does not mention Private Cloud Compute.
- The plan's §I now points here, the research notes carry the macOS 27 correction, and the
  roadmap lists the rung as parked with the three conditions rather than as open work.
- The first of the three conditions is the one most likely to move: when macOS 27 ships and the
  deployment target is raised, this ADR is re-read against Apple's entitlement page of that day.
  If the entitlement still requires App Store distribution, the rung is dropped from the plan
  rather than parked again.
