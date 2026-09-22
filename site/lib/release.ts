/** What the install section needs to know about the newest release. */
export type Release = {
  /** The version without the leading "v", e.g. "1.3.0". */
  version: string;
  /** Where the DMG downloads from. Falls back to the release page when the asset is not found. */
  dmgURL: string;
  /** The release page on GitHub. */
  releaseURL: string;
};

/**
 * The release the page falls back to when GitHub cannot be asked: at build time without network,
 * or when the unauthenticated API budget of sixty requests an hour is spent. The version is the
 * last one shipped when this file was written; the link deliberately points at the release list
 * rather than a DMG that may no longer exist.
 */
const FALLBACK: Release = {
  version: "1.4.0",
  dmgURL: "https://github.com/schnaq/shepherd/releases/latest",
  releaseURL: "https://github.com/schnaq/shepherd/releases/latest",
};

type ReleaseResponse = {
  tag_name?: string;
  html_url?: string;
  assets?: { name?: string; browser_download_url?: string }[];
};

/** Asks GitHub for the latest release, at most once an hour per deployment. */
export async function latestRelease(): Promise<Release> {
  try {
    const response = await fetch(
      "https://api.github.com/repos/schnaq/shepherd/releases/latest",
      {
        headers: {
          Accept: "application/vnd.github+json",
          "User-Agent": "shepherd.schnaq.com",
        },
        next: { revalidate: 3600 },
      },
    );
    if (!response.ok) return FALLBACK;
    const json = (await response.json()) as ReleaseResponse;
    const tag = json.tag_name;
    if (!tag) return FALLBACK;
    const version = tag.replace(/^v/, "");
    const releaseURL = json.html_url ?? FALLBACK.releaseURL;
    const dmg = json.assets?.find((asset) => asset.name === `Shepherd-${version}.dmg`);
    return { version, dmgURL: dmg?.browser_download_url ?? releaseURL, releaseURL };
  } catch {
    return FALLBACK;
  }
}
