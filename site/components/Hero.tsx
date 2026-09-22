import type { Release } from "@/lib/release";
import { InboxDemo } from "@/components/InboxDemo";

export function Hero({ release }: { release: Release }) {
  return (
    <section className="hero" id="top">
      <div className="wrap">
        <div className="hero-copy">
          <h1>Agents open pull requests faster than anyone can read them.</h1>
          <p className="lead">
            Shepherd is a native macOS inbox for every pull request from every repository you
            care about. Triage, review and merge from the keyboard, and know at a glance whether
            an agent or a person wrote it.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#install">Install with Homebrew</a>
            <a className="button" href={release.dmgURL}>Download Shepherd {release.version}</a>
          </div>
          <p className="hero-meta">
            macOS 26 Tahoe on Apple Silicon. Open source under the MIT licence. Your data stays on your Mac.
          </p>
        </div>
        <InboxDemo />
      </div>
    </section>
  );
}
