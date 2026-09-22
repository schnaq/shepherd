"use client";

import { useEffect, useState } from "react";

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 1800);
    return () => window.clearTimeout(timer);
  }, [copied]);

  return (
    <button
      type="button"
      className="copy"
      data-copied={copied ? "true" : undefined}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setCopied(true);
        } catch {
          // The clipboard is unavailable in some embedded browsers; the command is selectable text
          // right beside the button, so there is nothing more to do.
        }
      }}
      aria-live="polite"
    >
      {copied ? "Copied" : "Copy"}
    </button>
  );
}
