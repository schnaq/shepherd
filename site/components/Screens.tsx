import Image from "next/image";
import diff from "@/public/diff.png";
import inbox from "@/public/inbox.png";

export function Screens() {
  return (
    <section className="section">
      <div className="wrap screens">
        <h2 className="visually-hidden">Two screens</h2>
        <figure className="screen">
          <Image
            src={diff}
            alt="Shepherd's review screen, in the German localisation: a file list on the left ordered by risk, a side-by-side diff in the middle, and approve, request changes and merge buttons in the corner"
            sizes="(max-width: 1100px) 100vw, 1100px"
          />
          <figcaption>
            The review screen. Files that touch security-sensitive paths come first, the diff is the
            engine from VS Code, and approving is one keystroke.
          </figcaption>
        </figure>
        <figure className="screen">
          <Image
            src={inbox}
            alt="Shepherd's inbox, in the German localisation: a rail with smart views, risk and repository facets, a list of pull requests with CI state and diff size, and a detail panel with checks and an on-device summary"
            sizes="(max-width: 1100px) 100vw, 1100px"
          />
          <figcaption>
            The inbox. Grouped by repository, review state or source, with CI and diff size on every
            row, and an on-device summary in the panel. Shepherd speaks English and German; both
            screenshots show the German side.
          </figcaption>
        </figure>
      </div>
    </section>
  );
}
