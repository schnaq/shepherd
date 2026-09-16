# Releasing Shepherd

How a Shepherd release is made: a Developer-ID-signed, notarized DMG on GitHub Releases, an
appcast Sparkle reads from that same release, and a Homebrew cask that points at it
([ADR 0010](adr/0010-distribution-dmg-homebrew.md)).

Everything is already committed and wired up. What is **not** here — and cannot be, because it is
personal to the maintainer — is an Apple Developer ID certificate and a Sparkle signing key.
Until those exist:

- the app builds and runs normally,
- "Check for Updates…" is disabled, and Settings → Account says in one line why,
- `.github/workflows/release.yml` refuses to run and names the missing secrets,
- `Scripts/release.sh` refuses to run and names the missing environment variables.

Nothing in the app or in CI breaks in the meantime. [§ One-time setup](#one-time-setup) is the
list of things to do once; [§ Making a release](#making-a-release) is what happens every time
afterwards.

---

## One-time setup

Six steps. Steps 1–2 need an Apple Developer Program membership; steps 3–6 do not.

### 1. Developer ID Application certificate

Requires an [Apple Developer Program](https://developer.apple.com/programs/) membership.
Shepherd is distributed outside the App Store, so the certificate type is **Developer ID
Application** — not "Apple Development" and not "Mac App Distribution".

The short path:

```sh
# Xcode → Settings… → Accounts → (your Apple ID) → Manage Certificates… → + →
#   "Developer ID Application"
```

Then confirm the Mac can see it, and copy the full name of the identity:

```sh
security find-identity -v -p codesigning
#   1) 0A1B… "Developer ID Application: Jane Doe (AB12CD34EF)"
```

`Developer ID Application: Jane Doe (AB12CD34EF)` — the whole string, quotes excluded — is the
value of `CODESIGN_IDENTITY`. `AB12CD34EF` is the team id.

Then export it, certificate **and** private key together, for the release workflow to use:

```sh
# Keychain Access → login → My Certificates → select the certificate AND the key under it
#   (⌘-click both) → right-click → Export 2 items… → Personal Information Exchange (.p12)
base64 -i devid.p12 | pbcopy   # → MACOS_DEVID_CERT_P12_BASE64 in Infisical
rm -P devid.p12
```

> Export **both rows**. A `.p12` holding only the certificate, or only the key, imports without
> complaint and then yields no usable identity — `Scripts/ci-signing-setup.sh` catches that in
> two seconds and says so, rather than letting it surface as `errSecInternalComponent` after a
> twenty-minute build.

> **The runner keeps no signing material.** An earlier version of this document asked you to
> install the certificate in the runner's login keychain; that does not work. A runner installed
> with `svc.sh` is a LaunchAgent, so it runs in its user's Aqua session, while an
> `unlock-keychain` typed over SSH unlocks the keychain for the SSH session only — the runner's
> session still sees it locked and every `codesign` dies with `errSecInternalComponent`. The
> release job therefore builds its own keychain from the `.p12` above and deletes it afterwards
> (`Scripts/ci-signing-setup.sh`). A new runner needs Xcode and nothing else.

### 2. Notarization credentials

Apple notarizes the DMG. `notarytool` needs credentials, and there are two kinds — get both,
because they are used in different places.

**On your own Mac** (an app-specific password, stored once in the Keychain):

```sh
# Create an app-specific password at https://account.apple.com → Sign-In and Security
xcrun notarytool store-credentials "shepherd-notary" \
  --apple-id "you@example.com" \
  --team-id "AB12CD34EF" \
  --password "abcd-efgh-ijkl-mnop"
```

`shepherd-notary` is then the value of `NOTARY_KEYCHAIN_PROFILE` for local runs.

**For CI** (an App Store Connect API key — no Apple ID, no 2FA prompt):

1. <https://appstoreconnect.apple.com> → Users and Access → Integrations → App Store Connect
   API → **Team Keys** → +
2. Access: **Developer** is enough for notarization.
3. Download `AuthKey_XXXXXXXXXX.p8`. **Apple lets you download it exactly once.**
4. Note the **Key ID** (`XXXXXXXXXX`) and the **Issuer ID** (a UUID, shown above the key list).

### 3. Sparkle signing keys

Sparkle verifies every update with an ed25519 signature. The private half signs releases; the
public half is baked into the app.

The tools ship with Sparkle. After one Release build they are in the derived-data tree:

```sh
xcodegen generate
xcodebuild -project Shepherd.xcodeproj -scheme Shepherd -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/release \
  CODE_SIGNING_ALLOWED=NO build
SPARKLE_BIN=$(dirname "$(find .build/release/SourcePackages/artifacts -name generate_keys | head -1)")
echo "$SPARKLE_BIN"
```

(Alternatively, download `Sparkle-2.9.6.tar.xz` from
<https://github.com/sparkle-project/Sparkle/releases> and use its `bin/` directory.)

Generate the key pair. It is stored in your **login Keychain**, as an item named
"Private key for signing Sparkle updates":

```sh
"$SPARKLE_BIN/generate_keys"
```

It prints the public key. Paste that value into `project.yml`, replacing the placeholder:

```yaml
        SUPublicEDKey: REPLACE_WITH_SUPublicEDKey_FROM_generate_keys   # ← replace this line
```

Print it again at any later time with `"$SPARKLE_BIN/generate_keys" -p`.

Export the private key once, for the GitHub secret, and then destroy the file:

```sh
"$SPARKLE_BIN/generate_keys" -x sparkle-private-key.txt
cat sparkle-private-key.txt     # → the value of the SPARKLE_PRIVATE_KEY secret
rm -P sparkle-private-key.txt
```

> **Back up the private key** (a password manager is the right place). Losing it means no
> existing installation can ever be updated again: a new key means a new `SUPublicEDKey`, and an
> installed app only trusts the key it was built with. There is no recovery path, by design.
>
> `sparkle-private-key*.txt` and `*.p8` are in `.gitignore` as a safety net, but the right place
> for both is outside the working tree.

### 4. GitHub secrets

Settings → Secrets and variables → Actions → New repository secret.

| Secret | Value | Required |
| --- | --- | --- |
| `INFISICAL_CLIENT_ID` | machine-identity client id, for the certificate below | yes |
| `INFISICAL_CLIENT_SECRET` | its client secret | yes |
| `INFISICAL_API_URL` | the Infisical base URL, e.g. `https://secrets.schnaq.com` | yes |
| `SPARKLE_PRIVATE_KEY` | the contents of `sparkle-private-key.txt` (step 3) | yes |
| `NOTARY_API_KEY_ID` | the Key ID, e.g. `X1Y2Z3W4V5` (step 2) | yes |
| `NOTARY_API_ISSUER_ID` | the Issuer UUID (step 2) | yes |
| `NOTARY_API_KEY_P8` | the **entire** contents of `AuthKey_XXXXXXXXXX.p8`, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines (step 2) | yes |

The workflow's first step checks all seven and aborts with the names of the missing ones before
anything is built.

And in Infisical, under the project, environment and path named by `release.yml`'s `env:` block
(`shepherd` / `prod` / `/macos` as committed):

| Infisical secret | Value |
| --- | --- |
| `MACOS_DEVID_CERT_P12_BASE64` | the base64 from step 1 |
| `MACOS_DEVID_CERT_PASSWORD` | the password that `.p12` was exported with |

There is deliberately no `CODESIGN_IDENTITY` and no `DEVELOPMENT_TEAM`. The signing identity is
resolved on the runner, as the certificate's SHA-1, from the keychain the job just built — a
name has to be matched against a search list, and a team has to be matched against a
certificate, and both of those matches have their own ways to fail. A hash has none.

### 5. Commit the public key

`SUPublicEDKey` is the one value from this setup that belongs in the repository — it is public by
definition. Commit it on its own:

```sh
git add project.yml && git commit -m "chore(release): add the Sparkle public key"
```

### 6. Homebrew tap

Create a repository named **`homebrew-tap`** under the `schnaq` account (the `homebrew-` prefix
is what makes `brew tap schnaq/tap` work), then:

```sh
git clone https://github.com/schnaq/homebrew-tap.git && cd homebrew-tap
mkdir -p Casks
cp /path/to/review/Scripts/homebrew/shepherd.rb Casks/shepherd.rb
# fill in version + sha256 (see § Making a release, step 5)
brew audit --cask --online Casks/shepherd.rb
git add Casks/shepherd.rb && git commit -m "shepherd 0.1.0" && git push
```

Users then install with:

```sh
brew install --cask schnaq/tap/shepherd
```

Submitting to `homebrew/homebrew-cask` itself (which is what makes plain
`brew install --cask shepherd` work) requires a project with a release history and some
visibility; the own tap is the right first step and stays valid afterwards.

---

## Making a release

1. **Bump the version** in `project.yml`. Both keys, always:

   ```yaml
           CFBundleShortVersionString: "0.2.0"   # what humans see
           CFBundleVersion: "2"                  # what Sparkle compares — must only ever go up
   ```

   `Scripts/release.sh` aborts if `CFBundleVersion` is not higher than every build number the
   published appcast already lists, and if the tag disagrees with
   `CFBundleShortVersionString`. Those two guards are the reason a bad version is a failed
   release rather than a silent one.

2. **Check the dependency notices.** If a dependency was added, removed or bumped since the last
   release, update [`NOTICES.md`](../NOTICES.md).

3. **Tag and push.**

   ```sh
   git commit -am "chore(release): 0.2.0"
   git tag v0.2.0
   git push origin main --tags
   ```

   That starts `.github/workflows/release.yml`, which builds and tests the diff-viewer bundle,
   generates the project, runs the ShepherdKit and app test suites (a tag push does not trigger
   `ci.yml`, so the release runs them itself), then `Scripts/release.sh`, and publishes a GitHub
   release with three assets:

   | Asset | What it is |
   | --- | --- |
   | `Shepherd-0.2.0.dmg` | notarized, stapled, what humans download and what the cask installs |
   | `Shepherd-0.2.0.zip` | the same stapled `.app`, zipped |
   | `appcast.xml` | the Sparkle feed, with this release prepended |

   To re-run a release whose *upload* failed without moving the tag, use Actions → Release → Run
   workflow and type the version.

4. **Verify** — a minute, and it catches everything that matters:

   ```sh
   gh release download v0.2.0 -p 'Shepherd-*.dmg'
   xcrun stapler validate Shepherd-0.2.0.dmg
   spctl --assess -vv --type open --context context:primary-signature Shepherd-0.2.0.dmg
   curl -fsSL https://github.com/schnaq/review/releases/latest/download/appcast.xml | head -20
   ```

   The last command is the app's actual feed URL. If it does not return this release's item, the
   release is a draft or a prerelease — GitHub's `latest` only follows published, non-prerelease
   releases, and the in-app updater will not see it.

5. **Update the Homebrew cask** in `schnaq/homebrew-tap`:

   ```sh
   shasum -a 256 Shepherd-0.2.0.dmg
   # → paste version + sha256 into Casks/shepherd.rb, commit, push
   ```

6. **Smoke-test the update path** once per release cycle, on a Mac other than the build machine:
   install the *previous* release, then Shepherd → Check for Updates…. This is the only test that
   exercises the signature, the feed and the installer together.

---

## The feed URL

The app's `SUFeedURL` is:

```
https://github.com/schnaq/review/releases/latest/download/appcast.xml
```

`releases/latest/download/<asset>` is a permanent GitHub URL that redirects to the newest
published, non-prerelease release's asset of that name. So publishing the release *is*
publishing the feed: there is no second host, no `gh-pages` branch, and no commit that has to
land after the tag for updates to start flowing. Two consequences worth knowing:

- **A draft or prerelease release does not update the feed.** That is usually what you want, and
  the workflow warns when it made a draft.
- **The appcast is extended, not regenerated.** `Scripts/release.sh` downloads the currently
  published feed and prepends the new item, keeping the last ten. The only copy of the release
  history is the one that is online — so if a run reports "No published appcast found … starting
  a new feed" for anything but the very first release, stop and find out why before publishing.

---

## Running the pipeline locally

The whole script runs on a maintainer's Mac, which is how it is debugged:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Jane Doe (AB12CD34EF)"
export NOTARY_KEYCHAIN_PROFILE="shepherd-notary"
export SPARKLE_PRIVATE_KEY="$(cat ~/secure/sparkle-private-key.txt)"
./Scripts/release.sh
```

Useful variations — the full list is in the header of `Scripts/release.sh`:

```sh
SKIP_NOTARIZATION=1 ./Scripts/release.sh   # sign and package, skip the trip to Apple
ALLOW_UNSIGNED=1    ./Scripts/release.sh   # no identity, no keys, no notarization at all
```

**`ALLOW_UNSIGNED=1` is the one to run today.** It exercises every step of the pipeline —
build, DMG, ZIP, appcast — with no Apple account and with the `SUPublicEDKey` placeholder still
in place, and it prints loud warnings that the artefacts must not be published. It is the way to
find out that the pipeline works before spending money on a membership.

---

## Bumping Sparkle

Sparkle is pinned to an exact version in `project.yml` (`packages: Sparkle: exactVersion:`),
because the generated `Shepherd.xcodeproj` — and with it `Package.resolved` — is gitignored, so a
version *range* could resolve differently on two machines building the same commit.

To bump: change `exactVersion`, run `xcodegen generate`, build, and update Sparkle's version in
[`NOTICES.md`](../NOTICES.md). A Sparkle major-version bump is an API change and needs a look at
`Shepherd/Support/UpdateController.swift`.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `errSecInternalComponent` from `codesign` | The build machine's login keychain is locked, or the Developer ID certificate is in a different keychain. Unlock it: `security unlock-keychain ~/Library/Keychains/login.keychain-db`. |
| `SUPublicEDKey in project.yml is still the placeholder` | [Step 3](#3-sparkle-signing-keys) has not been done, or the public key was pasted with a line break in it. |
| `Could not find Sparkle's sign_update` | The Release build did not run, or derived data was cleaned between build and signing. Set `SPARKLE_BIN_DIR` to Sparkle's `bin` directory. |
| Notarization returns `Invalid` | `xcrun notarytool log <submission-id> --keychain-profile shepherd-notary` names the exact file and reason. Almost always a nested binary without hardened runtime or without a secure timestamp. |
| "Check for Updates…" is greyed out in a release build | The shipped `Info.plist` has no usable `SUPublicEDKey` or no `SUFeedURL`. Settings → Account states which. |
| The app finds no update although the release is published | The release is a prerelease or a draft, `appcast.xml` was not attached to it, or `CFBundleVersion` was not raised. |
| `The signature sign_update just produced does not verify` | `SPARKLE_PRIVATE_KEY` is truncated — a copy-paste that lost characters, or a secret stored with surrounding quotes. |
| `'1.2.0-beta' is not a version` | The workflow accepts digits and dots only. Prerelease versions are deliberately unsupported: `releases/latest` skips prereleases, so a `-beta` release could never reach the feed anyway. Ship betas as an unlisted DMG built locally with `SKIP_NOTARIZATION` unset and no appcast entry. |
