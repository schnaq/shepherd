import Image from "next/image";
import icon from "@/public/icon.png";

export function Nav() {
  return (
    <header className="nav">
      <div className="wrap nav-inner">
        <a className="brand" href="#top" aria-label="Shepherd, back to the top">
          <Image src={icon} alt="" width={28} height={28} priority />
          <span>Shepherd</span>
        </a>
        <nav aria-label="Sections">
          <ul className="nav-links">
            <li><a href="#what">What it does</a></li>
            <li><a href="#privacy">Privacy</a></li>
            <li><a href="#install">Install</a></li>
            <li><a href="https://github.com/schnaq/shepherd">GitHub</a></li>
          </ul>
        </nav>
      </div>
    </header>
  );
}
