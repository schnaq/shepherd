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
# or define an AES, ChaChaPoly or HPKE type, `SecKeyCreateEncryptedData`, or a CommonCrypto
# cipher or key derivation? The Mac target's settings sync does (`SettingsSyncCrypto.swift`:
# AES-GCM, PBKDF2), which is exactly the file that must never reach the phone. If this fails,
# re-decide the plist key before uploading.
#
# Every Mach-O file in the bundle is read, not just the main executable: in a Debug build the
# executable is a small launcher and the code lives in `Shepherd.debug.dylib`, and an embedded
# framework or app extension added later carries code of its own. Defined symbols are read as
# well as imported ones, but only an unstripped build still has them: the Debug simulator build
# the `ios` job in .github/workflows/ci.yml scans keeps them, so that scan is what catches a
# cipher compiled in from a package. The archived Release app Scripts/testflight.sh scans is
# stripped to its imports, so before an upload this sees what the app calls in the system's
# libraries (CryptoKit, Security, CommonCrypto) and nothing it defines itself — the packages are
# the same in both builds, which is why the push's Debug scan covers the rest.
#
set -euo pipefail

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

APP=${1:-}
[[ -d "$APP" ]] || die "Usage: $0 path/to/Shepherd.app"

# Demangled Swift names (`CryptoKit.AES.GCM.seal…`, `CryptoKit.ChaChaPoly…`,
# `CryptoKit.HPKE…`), Security's public-key encryption and the C names of CommonCrypto's cipher
# and PBKDF2 entry points.
PATTERN='AES|ChaChaPoly|HPKE|SecKeyCreateEncryptedData|_CCCrypt|_CCKeyDerivationPBKDF'

scanned=0
# Executable regular files, which is every Mach-O in an app bundle and few others; `file` sorts
# out the rest (a stray script) rather than `nm` failing on it.
while IFS= read -r -d '' binary; do
    [[ $(file -b "$binary") == Mach-O* ]] || continue
    # Captured before matching: `nm … | grep -q` under pipefail can lose to SIGPIPE when grep
    # exits early, and an `if` would read that as "no match". `-g`: external symbols, imported
    # and defined; a local symbol is not an API anyone calls.
    symbols=$(nm -g "$binary") || die "nm could not read $binary"
    hits=$(printf '%s\n' "$symbols" | xcrun swift-demangle | grep -E "$PATTERN" || true)
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" >&2
        die "${binary#"$APP"/} carries a cipher (above). Re-check ITSAppUsesNonExemptEncryption in project.yml (ADR 0044) before uploading."
    fi
    printf '    %s: %s symbols, no cipher\n' "${binary#"$APP"/}" "$(printf '%s\n' "$symbols" | wc -l | tr -d ' ')"
    scanned=$((scanned + 1))
done < <(find "$APP" -type f -perm -111 -print0)
[[ $scanned -gt 0 ]] || die "No Shepherd binary found in $APP."
