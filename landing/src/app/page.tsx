import { CtaBand } from "@/components/site/cta-band";
import { Faq } from "@/components/site/faq";
import { Features } from "@/components/site/features";
import { Hero } from "@/components/site/hero";
import { HowItWorks } from "@/components/site/how-it-works";
import { QuickStart } from "@/components/site/quick-start";
import { Security } from "@/components/site/security";
import { SiteFooter } from "@/components/site/site-footer";
import { SiteHeader } from "@/components/site/site-header";

export default function Home() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      <SiteHeader />
      <main id="content">
        <Hero />
        <Features />
        <HowItWorks />
        <Security />
        <QuickStart />
        <Faq />
        <CtaBand />
      </main>
      <SiteFooter />
    </div>
  );
}
