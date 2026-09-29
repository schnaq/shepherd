import type { NextConfig } from "next";
import { createMDX } from "fumadocs-mdx/next";

const nextConfig: NextConfig = {
  // Screenshots are served from /public and are already the size they are shown at, so the
  // optimiser only has to produce the responsive variants.
  images: { formats: ["image/avif", "image/webp"] },
  poweredByHeader: false,
};

// Compiles the user guide in content/docs (MDX) for the pages under /docs.
export default createMDX()(nextConfig);
