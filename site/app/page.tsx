import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Fact } from "@/components/Fact";
import { Features } from "@/components/Features";
import { Screens } from "@/components/Screens";
import { Privacy } from "@/components/Privacy";
import { Install } from "@/components/Install";
import { Footer } from "@/components/Footer";
import { latestRelease } from "@/lib/release";

export default async function Page() {
  const release = await latestRelease();
  return (
    <>
      <Nav />
      <main>
        <Hero release={release} />
        <Fact />
        <Features />
        <Screens />
        <Privacy />
        <Install release={release} />
      </main>
      <Footer />
    </>
  );
}
