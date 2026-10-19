#!/usr/bin/env bash
#
# The iPhone app's export-compliance guard (ADR 0044).
#
#   Scripts/check-phone-encryption.sh path/to/Shepherd.app
#
# `ITSAppUsesNonExemptEncryption` is NO in project.yml, and that answer is only true while the
# binary carries no cipher of its own. It does carry CryptoKit — SHA-256 and HMAC, for
# `SigV4Signer` and for the App Attest signing inside ClaudeForFoundationModels — which
# authenticates rather than encrypts and is exempt, so "is CryptoKit linked" is the wrong
# question: it would stop every build. This asks the right one, by symbol: does the app import
# an AES or ChaChaPoly type, or a CommonCrypto cipher or key derivation? The Mac target's
# settings sync does (`SettingsSyncCrypto.swift`: AES-GCM, PBKDF2), which is exactly the file
# that must never reach the phone. If this fails, re-decide the plist key before uploading.
#
# The debug dylib is read too, not just the main executable: in a Debug build the executable is a
# small launcher and the code lives in `Shepherd.debug.dylib`, so checking the executable alone
# would pass for the wrong reason. Run by Scripts/testflight.sh on the archived Release app and
# by the `ios` job in .github/workflows/ci.yml on the Debug simulator build.
#
set -euo pipefail

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

APP=${1:-}
[[ -d "$APP" ]] || die "Usage: $0 path/to/Shepherd.app"

# Demangled Swift names (`CryptoKit.AES.GCM.seal…`, `CryptoKit.ChaChaPoly…`) and the C names of
# CommonCrypto's cipher and PBKDF2 entry points.
PATTERN='AES|ChaChaPoly|_CCCrypt|_CCKeyDerivationPBKDF'

scanned=0
for binary in "$APP/Shepherd" "$APP/Shepherd.debug.dylib"; do
    [[ -f "$binary" ]] || continue
    # Captured before matching: `nm … | grep -q` under pipefail can lose to SIGPIPE when grep
    # exits early, and an `if` would read that as "no match".
    symbols=$(nm -u "$binary") || die "nm could not read $binary"
    hits=$(printf '%s\n' "$symbols" | xcrun swift-demangle | grep -E "$PATTERN" || true)
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" >&2
        die "$(basename "$binary") imports a cipher (above). Re-check ITSAppUsesNonExemptEncryption in project.yml (ADR 0044) before uploading."
    fi
    printf '    %s: %s imported symbols, no cipher\n' "$(basename "$binary")" "$(printf '%s\n' "$symbols" | wc -l | tr -d ' ')"
    scanned=$((scanned + 1))
done
[[ $scanned -gt 0 ]] || die "No Shepherd binary found in $APP."
