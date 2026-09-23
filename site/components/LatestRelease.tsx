/** The newest release on GitHub: its page, which carries the DMG, the ZIP and the notes. */
export const LATEST_RELEASE_URL = "https://github.com/schnaq/shepherd/releases/latest";

/**
 * The current version, as GitHub reports it, drawn by shields.io.
 *
 * A badge rather than a number baked into the page: the page is static, and a version written into
 * it at build time is wrong from the moment the next release ships until someone redeploys. The
 * badge asks GitHub every time it is shown, so it is always the release the button leads to.
 */
export function LatestRelease() {
  return (
    <a className="release-badge" href={LATEST_RELEASE_URL} aria-label="Latest release on GitHub">
      {/* eslint-disable-next-line @next/next/no-img-element -- an external SVG badge, not a photo */}
      <img
        src="https://img.shields.io/github/v/release/schnaq/shepherd?style=flat-square&label=latest&color=5b4bd6"
        alt="Latest release on GitHub"
        height={20}
      />
    </a>
  );
}
