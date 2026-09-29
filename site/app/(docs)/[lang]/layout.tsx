import type { Metadata } from "next";
import Image from "next/image";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { i18nProvider, uiTranslations } from "fumadocs-ui/i18n";
import { RootProvider } from "fumadocs-ui/provider/next";
import { LATEST_RELEASE_URL } from "@/components/LatestRelease";
import { i18n } from "@/lib/i18n";
import { source } from "@/lib/source";
import icon from "@/public/icon.png";
import "./docs.css";

// A root layout of its own, apart from the product page's: crossing between the two is a full
// page load, so the docs' Tailwind never reaches the product page and its styles never reach here.
export async function generateMetadata({ params }: LayoutProps<"/[lang]">): Promise<Metadata> {
  const name = (await params).lang === "de" ? "Shepherd-Doku" : "Shepherd docs";
  return {
    metadataBase: new URL("https://shepherd.schnaq.com"),
    title: { default: name, template: `%s · ${name}` },
    description: "How to set up and use Shepherd, the review inbox for the pull request flood.",
    icons: { icon: "/icon.png", apple: "/icon.png" },
  };
}

export const dynamicParams = false;

export function generateStaticParams() {
  return i18n.languages.map((lang) => ({ lang }));
}

// Fumadocs' own labels (search, table of contents, page actions). German covers what a reader
// sees; anything left out stays English.
const translations = i18n
  .translations()
  .extend(uiTranslations())
  .add({
    en: { displayName: "English" },
    de: {
      displayName: "Deutsch",
      "Search(search trigger)": "Suchen",
      "Search(search dialog)": "Suchen",
      "No results found(search dialog)": "Keine Treffer",
      "On this page(table of contents)": "Auf dieser Seite",
      "No Headings(table of contents)": "Keine Überschriften",
      "Table of Contents(inline table of contents)": "Inhalt",
      "Next Page(pagination)": "Nächste Seite",
      "Previous Page(pagination)": "Vorige Seite",
      "Copy Markdown(page actions)": "Markdown kopieren",
      "Copied Markdown(page actions)": "Markdown kopiert",
      "Open(page actions)": "Öffnen",
      "View as Markdown(page actions)": "Als Markdown ansehen",
      "Open in GitHub(page actions)": "Auf GitHub öffnen",
      "Open in ChatGPT(page actions)": "In ChatGPT öffnen",
      "Open in Claude(page actions)": "In Claude öffnen",
      "Open in Cursor(page actions)": "In Cursor öffnen",
      "Open in Scira AI(page actions)": "In Scira AI öffnen",
      "Read {url}, I want to ask questions about it.(page actions)": "Lies {url}, ich möchte Fragen dazu stellen.",
      "Choose a language(language switcher)": "Sprache wählen",
      "Page Not Found(404 not found page)": "Seite nicht gefunden",
      "Back to Home(404 not found page)": "Zur Startseite",
    },
  });

export default async function Layout({ params, children }: LayoutProps<"/[lang]">) {
  const { lang } = await params;
  const isGerman = lang === "de";

  return (
    <html lang={lang} suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <RootProvider
          theme={{ defaultTheme: "dark" }}
          search={{ options: { type: "static" } }}
          i18n={i18nProvider(translations, lang)}
        >
          <DocsLayout
            tree={source.getPageTree(lang)}
            nav={{
              title: (
                <>
                  <Image src={icon} alt="" width={24} height={24} />
                  Shepherd
                </>
              ),
            }}
            links={[{ text: isGerman ? "Herunterladen" : "Download", url: LATEST_RELEASE_URL, external: true }]}
            githubUrl="https://github.com/schnaq/shepherd"
          >
            {children}
          </DocsLayout>
        </RootProvider>
      </body>
    </html>
  );
}
