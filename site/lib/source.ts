import { llms, loader } from "fumadocs-core/source";
import { defineDocs } from "fumadocs-mdx/macro";
import { i18n } from "@/lib/i18n";

// Reads content/docs. Keeps each page's Markdown for /llms.txt, /llms-full.txt and the
// "Copy Markdown" button.
const docs = defineDocs({ docs: { postprocess: { includeProcessedMarkdown: true } } });

export const source = loader({
  i18n,
  baseUrl: "/docs",
  source: docs.toFumadocsSource(),
});

export const docsLlms = llms(source, {
  renderPage: async (page) => `# ${page.data.title} (${page.url})

${await page.data.getText("processed")}`,
});

/** The segments of a page's Markdown route, app/llms.mdx/<lang>/docs/<slug>/content.md. */
export function markdownSegments(page: { slugs: string[] }) {
  return [...page.slugs, "content.md"];
}

export function markdownUrl(page: { slugs: string[]; locale?: string }) {
  return `/llms.mdx/${page.locale ?? i18n.defaultLanguage}/docs/${markdownSegments(page).join("/")}`;
}
