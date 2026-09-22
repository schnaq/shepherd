type Group = { name: string; summary: string; items: { lead: string; rest: string }[] };

const GROUPS: Group[] = [
  {
    name: "Review",
    summary: "Everything a review needs, without a browser tab.",
    items: [
      { lead: "Real diffs in the app.", rest: "Side by side or inline, syntax highlighted, with the files ordered by what deserves attention first." },
      { lead: "Full GitHub parity.", rest: "Inline comments, pending reviews, approve or request changes, thread replies, checks, and merge, squash or rebase." },
      { lead: "A focus session.", rest: "One keystroke walks you through every pull request waiting on you, over a queue frozen when you start." },
      { lead: "Nothing happens out of sight.", rest: "A merge on its way, a queued approval or a write GitHub refused shows on the row and in the review, with Retry right there." },
      { lead: "Saved replies and a checklist.", rest: "Reusable snippets in every comment field, and a per-repository checklist that prefills an empty review." },
    ],
  },
  {
    name: "Triage",
    summary: "Get through the pile, not just to it.",
    items: [
            { lead: "Claims beside the evidence.", rest: "What the description says it did, from tests added to fixes #142, next to what the diff and CI actually show. Look closer lets the on-device model point at the lines behind a claim; Shepherd finds every excerpt in the diff itself." },
      { lead: "Bulk triage.", rest: "Tick the green ones and approve or merge them behind one confirmation that lists what it will skip, and why." },
      { lead: "Search that understands.", rest: "Type what a pull request is about. On-device embeddings of titles, labels, branches and the diffs you have opened, never sent anywhere." },
      { lead: "Where it came from.", rest: "Claude Code, Copilot, Codex, Devin, Cursor or a colleague, detected on every row and usable as a filter next to repository and review state." },
      { lead: "The fleet.", rest: "What became of every agent's pull requests: merged, closed, reverted, rounds of changes. Counts, never a score." },
    ],
  },
  {
    name: "Automate",
    summary: "Send work back, on your terms.",
    items: [
      { lead: "Delegate to Claude Code.", rest: "Hand a pull request or a single finding to your local agent in an isolated worktree, with turn and budget caps." },
      { lead: "Merge when the checks pass.", rest: "Decided on the commit you read. If the head moves, the decision expires." },
      { lead: "Auto-merge rules.", rest: "Agent pull requests that are green, approved and mergeable get merged for you, narrowed by repository and label, with every decision in a local audit log." },
      { lead: "Webhooks, links and a CLI.", rest: "Signed events into n8n, shepherd:// links, Shortcuts, Spotlight, and a binary that drives the app from a terminal. Notifications name their pull request, so Siri can open or summarise the one it is about." },
    ],
  },
  {
    name: "Intelligence",
    summary: "Drafts, never submissions.",
    items: [
      { lead: "On-device first.", rest: "Heuristics always, Apple's on-device models where available, and your own key if you want one: Claude through Apple's own model interface, any OpenAI-compatible endpoint, Konduit or Ollama." },
      { lead: "Editable text.", rest: "A drafted review summary or inline comment lands in the field for you to change. Nothing is ever sent on your behalf." },
      { lead: "Translate and rewrite in place.", rest: "An on-device translation appears below the original, and Apple's Writing Tools work in every field you write in." },
    ],
  },
];

export function Features() {
  return (
    <section className="section" id="what">
      <div className="wrap">
        <div className="section-head">
          <h2>One inbox for every repository. Every action from the keyboard.</h2>
          <p>Shepherd keeps a local copy of what GitHub knows and lets you act on it fast.</p>
        </div>
        <div className="groups">
          {GROUPS.map((group) => (
            <div className="group" key={group.name}>
              <div className="group-name">
                <h3>{group.name}</h3>
                <p>{group.summary}</p>
              </div>
              <ul>
                {group.items.map((item) => (
                  <li key={item.lead}>
                    <strong>{item.lead}</strong> {item.rest}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
