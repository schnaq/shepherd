const HOSTS = [
  {
    name: "GitHub",
    host: "api.github.com",
    what: "Your pull requests, reviews and merges. Reads through GraphQL, writes through REST, all with the token you signed in with.",
    control: "Always. That is the job.",
  },
  {
    name: "Usage counts",
    host: "eu.i.posthog.com",
    what: "About once a day: the app version, the language, and which features were used, as categories and buckets. No identifier, nothing that could recognise this Mac again, and never a repository, a branch or a line of code.",
    control: "Off until you say yes when the app first opens, and one click to switch off again in Settings. Counting people rather than launches needs a random ID that is thrown away every month. That is a separate choice on the same screen.",
  },
  {
    name: "Updates",
    host: "github.com",
    what: "A daily check of the release feed. Sends the version you are on and nothing about your system.",
    control: "Switch it off in Settings.",
  },
  {
    name: "An AI endpoint you choose",
    host: "Anthropic, OpenAI-compatible, Konduit, Ollama",
    what: "The pull request's title, an excerpt of its description, the list of changed files, the relevant diff excerpt and your own notes, only for the draft you asked for. A colleague's comment never travels to a cloud endpoint.",
    control: "Off until you enter a key. On-device models need no key and no network.",
  },
  {
    name: "A bucket you own",
    host: "Your S3 endpoint",
    what: "Every setting and every secret in one object, encrypted on this Mac with AES-256-GCM before it leaves.",
    control: "Off until you set it up.",
  },
];

export function Privacy() {
  return (
    <section className="section" id="privacy">
      <div className="wrap">
        <div className="section-head">
          <h2>What leaves your Mac, and what never does.</h2>
        </div>
        <div className="privacy-intro">
          <p>
            Shepherd is local-first by construction. Pull requests, review drafts, the search index
            and the audit log live in a SQLite database in your Library folder. Tokens and keys live
            in the Keychain. There is no Shepherd account and no Shepherd server.
          </p>
          <p>This is the complete list of places the app talks to.</p>
        </div>
        <table className="hosts">
          <thead>
            <tr>
              <th scope="col">Where</th>
              <th scope="col">What</th>
              <th scope="col">You decide</th>
            </tr>
          </thead>
          <tbody>
            {HOSTS.map((row) => (
              <tr key={row.name}>
                <td>
                  {row.name}
                  <code>{row.host}</code>
                </td>
                <td>{row.what}</td>
                <td>{row.control}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="privacy-note">
          Crash and hang reports, if you turn them on, are written to disk and never uploaded. This
          page runs no analytics either. The full privacy notice, including the exact list of
          events and the legal basis for each, is in{" "}
          <a href="https://github.com/schnaq/shepherd/blob/main/docs/PRIVACY.md">the repository</a>.
        </p>
      </div>
    </section>
  );
}
