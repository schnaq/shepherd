import type { NextConfig } from "next";
import { createMDX } from "fumadocs-mdx/next";

const nextConfig: NextConfig = {
  // Screenshots are served from /public and are already the size they are shown at, so the
  // optimiser only has to produce the responsive variants.
  images: { formats: ["image/avif", "image/webp"] },
  poweredByHeader: false,
  // The user guide's pages live under app/(docs)/[lang]; English keeps the short /docs URLs.
  async rewrites() {
    return [
      { source: "/docs", destination: "/en/docs" },
      { source: "/docs/:path*", destination: "/en/docs/:path*" },
    ];
  },
  async redirects() {
    return [
      // The [lang] segment has no page of its own.
      { source: "/en", destination: "/docs", permanent: false },
      { source: "/de", destination: "/de/docs", permanent: false },
      { source: "/en/docs", destination: "/docs", permanent: true },
      { source: "/en/docs/:path*", destination: "/docs/:path*", permanent: true },
    ];
  },
};

// Compiles the user guide in content/docs (MDX) for the pages under /docs.
export default createMDX()(nextConfig);
