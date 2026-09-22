import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque } from "next/font/google";
import "./globals.css";

const display = Bricolage_Grotesque({
  subsets: ["latin"],
  weight: ["500", "700", "800"],
  variable: "--font-display",
  display: "swap",
});

const SITE = "https://shepherd.schnaq.com";
const TITLE = "Shepherd";
const DESCRIPTION =
  "A native macOS inbox for the pull request flood. Triage, review and merge from the keyboard, across every repository, with your data on your Mac.";

export const metadata: Metadata = {
  metadataBase: new URL(SITE),
  title: { default: `${TITLE}: a review inbox for the pull request flood`, template: `%s · ${TITLE}` },
  description: DESCRIPTION,
  applicationName: TITLE,
  keywords: ["pull request", "code review", "macOS", "Claude Code", "Copilot", "Codex", "GitHub"],
  authors: [{ name: "schnaq GmbH", url: "https://schnaq.com" }],
  openGraph: {
    type: "website",
    url: SITE,
    siteName: TITLE,
    title: `${TITLE}: a review inbox for the pull request flood`,
    description: DESCRIPTION,
    locale: "en",
  },
  twitter: { card: "summary_large_image", title: TITLE, description: DESCRIPTION },
  icons: { icon: "/icon.png", apple: "/icon.png" },
  alternates: { canonical: SITE },
};

export const viewport: Viewport = {
  themeColor: "#0b0c11",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={display.variable}>
      <body>{children}</body>
    </html>
  );
}
