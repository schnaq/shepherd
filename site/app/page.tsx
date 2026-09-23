import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Fact } from "@/components/Fact";
import { Features } from "@/components/Features";
import { Screens } from "@/components/Screens";
import { Privacy } from "@/components/Privacy";
import { Install } from "@/components/Install";
import { Footer } from "@/components/Footer";

export default function Page() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Fact />
        <Features />
        <Screens />
        <Privacy />
        <Install />
      </main>
      <Footer />
    </>
  );
}
