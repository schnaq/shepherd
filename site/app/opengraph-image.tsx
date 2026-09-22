import { ImageResponse } from "next/og";

export const alt = "Shepherd: a native macOS review inbox for pull requests from coding agents";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpenGraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: 72,
          background: "linear-gradient(135deg, #0b0c11 0%, #15161e 100%)",
          color: "#e8eaf0",
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 18, fontSize: 30, color: "#9aa1b2" }}>
          <div style={{ width: 44, height: 44, borderRadius: 11, background: "#5b4fd6" }} />
          Shepherd
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
          <div style={{ fontSize: 68, fontWeight: 700, lineHeight: 1.05, letterSpacing: -2, maxWidth: 980 }}>
            Agents open pull requests faster than anyone can read them.
          </div>
          <div style={{ fontSize: 30, color: "#9aa1b2", maxWidth: 900, lineHeight: 1.35 }}>
            A native macOS review inbox for every repository. Local-first, keyboard-driven, open source.
          </div>
        </div>
        <div style={{ display: "flex", gap: 32, fontSize: 24, color: "#636b7e" }}>
          <span>shepherd.schnaq.com</span>
          <span>macOS 26 Tahoe</span>
          <span>MIT</span>
        </div>
      </div>
    ),
    size,
  );
}
