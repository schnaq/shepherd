"use client";

import { useEffect, useRef, useState } from "react";

type Row = {
  repo: string;
  number: number;
  title: string;
  author: string;
  agent: boolean;
  ci: "green" | "red" | "amber";
  status: string;
  statusKind?: "fail" | "ok";
  added: number;
  removed: number;
  age: string;
};

type Section = { name: string; color: string; rows: Row[] };

/** The inbox as the app draws it: grouped by who wrote the change, CI and review state per row. */
const SECTIONS: Section[] = [
  {
    name: "Claude Code",
    color: "#8b74d9",
    rows: [
      { repo: "schnaq/konduit", number: 412, title: "Retry the auth suite when the token refresh races", author: "Claude Code", agent: true, ci: "green", status: "Approved", statusKind: "ok", added: 48, removed: 12, age: "2 h" },
      { repo: "schnaq/shepherd", number: 388, title: "Keep the appcast on the latest release", author: "Claude Code", agent: true, ci: "amber", status: "CI running", added: 19, removed: 4, age: "3 h" },
    ],
  },
  {
    name: "GitHub Copilot",
    color: "#6e9df2",
    rows: [
      { repo: "schnaq/unlock", number: 77, title: "Bump stripe-node to 14.2", author: "Copilot", agent: true, ci: "green", status: "Review requested", added: 2, removed: 2, age: "5 h" },
    ],
  },
  {
    name: "Codex",
    color: "#d9a13c",
    rows: [
      { repo: "schnaq/konduit", number: 915, title: "Extract the rate limiter into middleware", author: "Codex", agent: true, ci: "red", status: "1 check failing", statusKind: "fail", added: 210, removed: 96, age: "1 d" },
    ],
  },
  {
    name: "People",
    color: "#4cc38a",
    rows: [
      { repo: "schnaq/shepherd", number: 131, title: "Fix smart light example; fix attribute access", author: "mara", agent: false, ci: "green", status: "Review requested", added: 8, removed: 5, age: "1 d" },
    ],
  },
];

const ROWS = SECTIONS.flatMap((section) => section.rows);

export function InboxDemo() {
  const [selected, setSelected] = useState(0);
  const walked = useRef(false);
  const container = useRef<HTMLDivElement>(null);
  const visible = useRef(true);

  // The keys are only taken while the inbox is actually on screen, so a reader scrolled down to
  // the privacy table keeps `j` and `k` for whatever their browser does with them.
  useEffect(() => {
    const element = container.current;
    if (!element || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(([entry]) => {
      visible.current = entry.isIntersecting;
    }, { threshold: 0.3 });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // One orchestrated moment on load: the cursor walks down three rows, the way `j` would move
  // it. Skipped when the reader asked the system for less motion.
  useEffect(() => {
    if (walked.current) return;
    walked.current = true;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timers = [1, 2, 3].map((step) =>
      window.setTimeout(() => setSelected(step), 900 + step * 420),
    );
    return () => timers.forEach(window.clearTimeout);
  }, []);

  // `j` and `k` move the cursor for real, as in the app. Not while typing somewhere else, and
  // not when a modifier is held, so browser shortcuts keep working.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!visible.current) return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (target && ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)) return;
      if (target?.isContentEditable) return;
      if (event.key === "j") {
        event.preventDefault();
        setSelected((index) => Math.min(index + 1, ROWS.length - 1));
      } else if (event.key === "k") {
        event.preventDefault();
        setSelected((index) => Math.max(index - 1, 0));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  let index = -1;
  return (
    <>
    <p className="visually-hidden">
      An example of the inbox: five pull requests grouped by who wrote them, with the CI state,
      the review state and the size of the diff on every row. Press j and k to move the selection.
    </p>
    <div className="inbox" aria-hidden="true" ref={container}>
      <div className="inbox-bar" aria-hidden="true">
        <span className="inbox-lights"><i /><i /><i /></span>
        <strong>Needs my review</strong>
        <span>{ROWS.length} pull requests</span>
      </div>
      <ul className="inbox-list">
        {SECTIONS.map((section) => (
          <li key={section.name}>
            <div className="inbox-section">
              <i style={{ background: section.color }} aria-hidden="true" />
              {section.name}
            </div>
            <ul className="inbox-list">
              {section.rows.map((row) => {
                index += 1;
                const isSelected = index === selected;
                return (
                  <li key={`${row.repo}#${row.number}`} className="row" data-selected={isSelected ? "true" : undefined}>
                    <span className={`dot dot-${row.ci}`} aria-hidden="true" />
                    <span className="row-main">
                      <span className="row-ref">{row.repo.split("/")[1]} #{row.number}</span>
                      <span className="row-title">{row.title}</span>
                    </span>
                    <span className="row-side">
                      <span className={`chip ${row.agent ? "chip-agent" : "chip-human"}`}>{row.author}</span>
                      <span className={`chip ${row.statusKind ? `chip-${row.statusKind}` : ""}`}>{row.status}</span>
                      <span className="diff"><b>+{row.added}</b> <s>&minus;{row.removed}</s></span>
                      <span className="age">{row.age}</span>
                    </span>
                  </li>
                );
              })}
            </ul>
          </li>
        ))}
      </ul>
      <div className="inbox-foot">
        <span><kbd>j</kbd><kbd>k</kbd> move</span>
        <span><kbd>↩</kbd> open review</span>
        <span><kbd>x</kbd> select</span>
        <span><kbd>⌘K</kbd> search</span>
      </div>
    </div>
    </>
  );
}
