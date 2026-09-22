import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Screenshots are served from /public and are already the size they are shown at, so the
  // optimiser only has to produce the responsive variants.
  images: { formats: ["image/avif", "image/webp"] },
  poweredByHeader: false,
};

export default nextConfig;
