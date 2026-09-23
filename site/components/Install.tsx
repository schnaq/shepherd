import { LatestRelease, LATEST_RELEASE_URL } from "@/components/LatestRelease";
import { CopyButton } from "@/components/CopyButton";

const COMMAND = "brew install --cask schnaq/tap/shepherd";

export function Install() {
  return (
    <section className="section" id="install">
      <div className="wrap">
        <div className="section-head">
          <h2>Install in one line.</h2>
        </div>
        <div className="install-grid">
          <div className="terminal">
            <div className="terminal-bar">
              <span>Terminal</span>
              <CopyButton text={COMMAND} />
            </div>
            <pre><code><span className="prompt">$ </span>{COMMAND}</code></pre>
          </div>
          <div className="install-side">
            <p>
              Or download the DMG. Either way the app is notarized by Apple and keeps itself current
              through Sparkle, so you install once.
            </p>
            <div className="install-download">
              <a className="button" href={LATEST_RELEASE_URL}>Download the latest release</a>
              <LatestRelease />
            </div>
            <p>
              Needs macOS 27 Golden Gate on Apple Silicon (on macOS 26, 1.3 keeps working). Sign in with GitHub through the device flow, or
              paste a fine-grained personal access token.{" "}
              <a href={LATEST_RELEASE_URL}>Release notes</a>
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
