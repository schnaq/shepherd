# ADR 0014: End-to-end encrypted settings sync over the user's own S3 bucket

Status: Accepted (v1.x scope) · Date: 2026-09-01

## Context

A Shepherd install is not just a login. By the time it is useful it holds a sweep interval,
notification choices, an inbox facet and sort order, diff-viewer chrome, an agent registry the
user extended by hand, a delegation configuration with per-repository clone paths and guardrails,
an intelligence endpoint with a preset and a model name, and a webhook URL with an event
subscription. Behind four of those sit secrets: the GitHub token, an Anthropic key, an
OpenAI-compatible endpoint's key, and the webhook signing secret.

Setting a second Mac up therefore means an evening of retyping — and the retyping is the *easy*
part, because the secrets are not retypable: a fine-grained personal access token cannot be read
back from GitHub, so "sync my settings" that skips secrets leaves the user rotating tokens
instead of copying them. The founder's requirement was explicit: a new Mac with bucket access and
the passphrase should be **fully** set up, keys included.

Three shapes were on the table.

**iCloud (`NSUbiquitousKeyValueStore` / CloudKit).** Free, invisible, and the obvious macOS
answer — but it needs an Apple Developer team and iCloud entitlements, which ADR 0010's
DMG-and-Homebrew distribution and the "build it yourself from source" path do not have. It also
cannot carry Keychain items without Keychain sync, which the user cannot inspect. And it makes
Apple a party to the user's tokens, which is exactly what "local-first" was supposed to avoid.

**A Shepherd account server.** Solves everything and destroys the premise. ADR 0006's local-first
decision says GitHub is a sync target, not a backend; there is no server, no telemetry, and no
account other than the user's GitHub login. Introducing a hosted component to sync *preferences*
would be the single largest architectural regression available.

**The user's own S3-compatible bucket.** The user already has one, or can have one in five
minutes: STACKIT Object Storage (EU, and the primary case here), MinIO on a NAS, Hetzner, Wasabi,
Garage. It needs no account system, no server, no uptime commitment from us, and no entitlement.
The cost is that the *storage operator* can read whatever we put there — which is only a problem
if we put plaintext there.

So the decision is not really "where" but "what": the object has to be useless to whoever holds
it.

## Decision

- **Bring your own bucket.** Shepherd stores exactly one object, at
  `<prefix>/settings.enc.json` in a bucket the user names, on an S3-compatible endpoint the user
  names. There is no Shepherd server, no account, no registration and no discovery. Off by
  default, behind an enable toggle, like webhooks (ADR 0012).

- **One encrypted document containing everything, secrets included.** `SyncedSettingsDocument` is
  a versioned JSON document with an explicit group per settings area (sync, notifications,
  agents, intelligence, delegation, automation, appearance, account) plus a `secrets` object
  holding the GitHub token, the two AI keys and the webhook secret. Carrying secrets is the
  feature, not a convenience: without them the second Mac is not set up.

- **Passphrase → key: PBKDF2-HMAC-SHA256, 600 000 iterations, 32-byte random salt per upload.**
  `CCKeyDerivationPBKDF` from CommonCrypto, because CryptoKit has no password-based KDF. 600 000
  is OWASP's current floor for this construction and is paid exactly twice per user action.

- **Content encryption: AES-256-GCM via CryptoKit**, fresh 12-byte nonce per upload. AES rather
  than ChaCha20-Poly1305 for two reasons: Apple Silicon has AES instructions, so at this size the
  cost is invisible; and AES-GCM is the AEAD every language's standard library speaks, so a user
  can decrypt their own backup with ten lines of Python. That is a real requirement for a
  local-first product — the format must not depend on Shepherd continuing to exist. The payload
  is stored as `ciphertext || tag`, the layout those libraries expect.

- **The envelope's metadata is authenticated (AAD).** Everything in the envelope except the
  payload — version, KDF name, iteration count, salt, cipher name, timestamp, device name — is
  fed to the AEAD as additional authenticated data, as a fixed newline-separated `key=value` byte
  string (deliberately not `JSONEncoder` output, so it stays reproducible across OS versions and
  by third-party tooling). Someone with write access to the bucket therefore cannot lower the
  iteration count, swap the salt or relabel which Mac wrote the object: the tag stops verifying.
  The nonce is excluded because it is already an AEAD input.

- **The passphrase is never uploaded and never written to `UserDefaults`.** It may be kept in the
  Keychain, behind an opt-in checkbox that is off by default; clearing the checkbox deletes the
  stored item rather than merely stopping new writes.

- **A wrong passphrase is one error, and it never yields half a document.** GCM verifies the tag
  before returning any plaintext, so a wrong key, an edited parameter and a flipped bit are
  indistinguishable and all surface as *"wrong passphrase or corrupted data"*. Presenting them
  differently would be both a lie and an oracle.

- **SigV4 by hand, for three operations, and no new dependency.** `GET`, `PUT` and `HEAD` on one
  object. An AWS SDK is several hundred thousand lines for that. The canonicalisation — the only
  part that is genuinely easy to get wrong — is a pure, testable type pinned to the official
  `aws-sig-v4-test-suite` vectors plus a signing-key vector, and the three requests Shepherd
  actually sends have their signatures asserted byte for byte. Path-style addressing is the
  default because S3-compatible providers serve it more reliably than virtual-hosted style;
  region and addressing are configurable. `https` only — no localhost exception, because this
  object carries the user's GitHub token.

- **Credentials in the Keychain, everything else in `UserDefaults`.** The access key pair and the
  optional passphrase are Keychain items (ADR 0004's rule, applied again); endpoint, bucket,
  region, prefix and addressing style are non-secret configuration.

- **Manual sync in v1, and the conflict story is a dialog.** Two buttons ("Upload settings",
  "Download settings") plus "Check remote", which does a `HEAD` and reports the object's
  `Last-Modified`, and a `GET` shows which Mac last wrote it. A download decrypts first and
  *then* asks for confirmation, naming the source Mac, the timestamp and how many secrets are
  about to be written. Applying replaces rather than merges — with one exception: an **absent**
  secret leaves this Mac's alone, so uploading from a Mac that never configured a webhook cannot
  silently disarm the Mac that did.

- **No background sync in v1.** This is a decision, not an omission. An automatic sync needs a
  conflict resolution story, and settings do not have one: "which sweep interval did I mean?" has
  no answer a machine can guess, and last-write-wins on a document that contains the GitHub token
  can quietly sign a Mac in as the wrong account. Two buttons and a confirmation dialog are
  honest about what is happening.

- **A GitHub token that arrives for a different account does not switch the session.** The token
  is written to the Keychain under its own login, and Settings says *"sign out and sign in again
  to use it"*. Replacing the token of the account that is already signed in does take effect
  immediately, because `RefreshingTokenProvider` reads the store on every request. Only the
  *access* token travels: device-flow refresh tokens are single-use and rotate, so copying one to
  a second Mac would guarantee that one of the two loses the race.

- **Placement follows ADR 0012's precedent.** All of it lives in the app target
  (`Shepherd/SettingsSync/`), because CryptoKit and CommonCrypto do not exist on Linux and
  `Packages/ShepherdKit` must keep building and testing there (`docs/ARCHITECTURE.md`). The parts
  that carry the risk — the envelope codec, the crypto, the SigV4 canonicalisation, the document
  codec, and capture/apply — are pure or seam-driven, so all of them are unit-tested without a
  bucket, a network or a Keychain.

## Threat model

What the design does and does not protect against, stated plainly.

| Adversary | What they see | Outcome |
| --- | --- | --- |
| The bucket operator (STACKIT, MinIO admin, whoever) | The object: version, KDF parameters, salt, nonce, timestamp, device name, ciphertext | No settings, no secrets. Metadata only. |
| Anyone who obtains the bucket credentials | The same object | The same. They can also **delete** or **overwrite** it — availability is not protected, confidentiality is. |
| Anyone who obtains bucket credentials *and* the passphrase | Everything | Full compromise, including the GitHub token. This is the trust boundary and it is exactly one secret wide. |
| A network observer | TLS to the endpoint | Nothing beyond the fact that Shepherd talked to a bucket. |
| A tamperer with write access | — | Cannot forge or modify a readable object: the payload and every metadata field are authenticated. They can replace the object with a valid envelope of their own, which will fail to decrypt under the user's passphrase. |
| A tamperer who **keeps an old object** they captured earlier | — | Can put a *previously valid* document back in the bucket, and it will decrypt: the envelope authenticates its contents, not its freshness. What that reintroduces on the next download is a since-rotated token or key. Not forgery and not silent — the download is manual, and the confirmation names the device that sealed the document and the date it was sealed before anything is written. Accepted rather than solved: detecting a rollback needs this Mac to remember what it last uploaded, and the row below is the cheaper answer for a single-user tool. |
| Someone with the user's unlocked Mac | Everything the Mac has anyway | Out of scope, as for every other secret Shepherd holds. |

Two consequences follow, and both are deliberate:

- **A lost passphrase means lost data.** There is no recovery, no reset, no escrow and no hint.
  Any of those would be a second way in, which is precisely what this design refuses to have. The
  Settings copy says so before the first upload rather than after.
- **The device name is metadata, in the clear.** It has to be: it is what makes "which Mac wrote
  this?" answerable before decrypting, which is what makes the download confirmation meaningful.
  It is sanitised to one bounded line and it is authenticated, so it cannot be forged, only read.

## Consequences

- The privacy line in CONTRIBUTING.md moves by one host, and only when the user names it: the
  S3-compatible endpoint they configured. Same shape as ADR 0012's webhook URL — off by default,
  one destination, user-typed.
- Shepherd now has a documented, versioned, non-proprietary at-rest format for its own
  configuration. A user can decrypt `settings.enc.json` with any AES-GCM implementation given the
  passphrase and the envelope's own parameters. That is a deliberate anti-lock-in property, and
  it is why the AAD is a hand-specified byte string rather than whatever `JSONEncoder` emits.
- The one object is also a **backup**. Not marketed as one — there is no history and a `PUT`
  replaces — but a user who uploads before reinstalling has their keys afterwards.
- `AppSettings` gained nine fields and the Keychain three items. Adding a *setting* to Shepherd
  now has a second obligation: add it to `SyncedSettingsDocument` and to both directions of
  `SettingsSyncApplier`, whose two functions are written as mirror images so the omission is
  visible in review. The tests capture-apply-capture a document with every field non-default,
  which is what actually catches it.
- What is **not** synced, and why: the SQLite cache (a cache; GitHub refills it), the outbox
  (machine-local pending work — syncing it would submit one Mac's queued review from another),
  viewed-file state, and window geometry.
- Additive changes to the document stay under `v: 1`: unknown fields are ignored and absent ones
  fall back to the local default, so an older Shepherd reading a newer document loses only the
  fields it never had. A change a reader *cannot* ignore bumps `v` — and the envelope has its own
  version for the same reason, so the crypto format and the settings format can move
  independently.
- Automatic sync, a second object per Mac, or per-field merge are all reachable from here without
  breaking the format. They each need a conflict decision, which is why none of them is in v1.
