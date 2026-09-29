import { defineI18n } from "fumadocs-core/i18n";

// English at /docs, German at /de/docs. A page's German text sits next to it as <name>.de.mdx;
// a page without one falls back to English. next.config.ts maps /docs onto the [lang] route.
export const i18n = defineI18n({
  defaultLanguage: "en",
  languages: ["en", "de"],
  hideLocale: "default-locale",
  parser: "dot",
});
