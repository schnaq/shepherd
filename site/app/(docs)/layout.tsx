import type { Metadata } from "next";
import Image from "next/image";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { RootProvider } from "fumadocs-ui/provider/next";
import { source } from "@/lib/source";
import icon from "@/public/icon.png";
import "./docs.css";

// A root layout of its own, apart from the product page's: crossing between the two is a full
// page load, so the docs' Tailwind never reaches the product page and its styles never reach here.
export const metadata: Metadata = {
  metadataBase: new URL("https://shepherd.schnaq.com"),
  title: { default: "Shepherd docs", template: "%s · Shepherd docs" },
  description: "How to set up and use Shepherd, the review inbox for the pull request flood.",
  icons: { icon: "/icon.png", apple: "/icon.png" },
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <RootProvider theme={{ defaultTheme: "dark" }}>
          <DocsLayout
            tree={source.getPageTree()}
            nav={{
              title: (
                <>
                  <Image src={icon} alt="" width={24} height={24} />
                  Shepherd
                </>
              ),
            }}
            links={[{ text: "Download", url: "https://github.com/schnaq/shepherd/releases/latest", external: true }]}
            githubUrl="https://github.com/schnaq/shepherd"
          >
            {children}
          </DocsLayout>
        </RootProvider>
      </body>
    </html>
  );
}
