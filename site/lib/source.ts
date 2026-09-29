import { llms, loader } from "fumadocs-core/source";
import { metaSchema, pageSchema } from "fumadocs-core/source/schema";
import { defineDocs } from "fumadocs-mdx/macro";

const docs = defineDocs({
  dir: "content/docs",
  docs: {
    schema: pageSchema,
    // Keeps each page's Markdown for /llms.txt, /llms-full.txt and the "Copy Markdown" button.
    postprocess: { includeProcessedMarkdown: true },
  },
  meta: { schema: metaSchema },
});

export const source = loader({
  baseUrl: "/docs",
  source: docs.toFumadocsSource(),
});

export const docsLlms = llms(source, {
  renderPage: async (page) => `# ${page.data.title} (${page.url})

${await page.data.getText("processed")}`,
});

/** Where a page's Markdown is served: /llms.mdx/docs/<slug>/content.md. */
export function markdownSegments(page: { slugs: string[] }) {
  return [...page.slugs, "content.md"];
}
