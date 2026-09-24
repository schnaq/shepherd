import { InboxDemo } from "@/components/InboxDemo";
import { LatestRelease, LATEST_RELEASE_URL } from "@/components/LatestRelease";

export function Hero() {
  return (
    <section className="hero" id="top">
      <div className="wrap">
        <div className="hero-copy">
          <h1>Agents open pull requests faster than anyone can read them.</h1>
          <p className="lead">
            Shepherd is a native macOS inbox for every pull request from every repository you
            care about. Triage, review and merge from the keyboard.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#install">Install with Homebrew</a>
            <a className="button" href={LATEST_RELEASE_URL}>Download the latest release</a>
            <LatestRelease />
          </div>
          <p className="hero-meta">
            macOS 27 Golden Gate on Apple Silicon. Open source under the MIT licence.
          </p>
        </div>
        <InboxDemo />
      </div>
    </section>
  );
}
