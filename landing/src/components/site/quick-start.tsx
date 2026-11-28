"use client"

import { ArrowUpRight } from "lucide-react"

import { CodeBlock } from "@/components/site/code-block"
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/components/ui/tabs"
import { useLocale } from "@/lib/i18n"

const snippets = {
  docker: `git clone https://github.com/thuupx/zalos.git
cd zalos/deploy/docker
cp .env.example .env   # set TS_AUTHKEY and TS_HOSTNAME
docker compose up -d --build
docker compose exec zalos zalos pair --role admin`,
  local: `cd zalos/deploy/docker
ZALOS_BIND_HOST=127.0.0.1 ZALOS_PUBLIC_HOST=127.0.0.1 \\
  docker compose -f compose.local.yaml up -d --build
docker compose -f compose.local.yaml exec zalos zalos pair --role admin`,
  client: `cd zalos/client
flutter pub get
flutter run`,
}

export function QuickStart() {
  const { locale, t } = useLocale()
  const onboardingUrl =
    locale === "vi" ? t.links.onboardingVi : t.links.onboardingEn

  return (
    <section
      id="quick-start"
      aria-labelledby="quick-start-title"
      className="scroll-mt-24 px-4 py-16 sm:px-6 sm:py-20 lg:px-8"
    >
      <div className="mx-auto max-w-[1200px]">
        <div className="max-w-2xl">
          <p className="text-sm font-semibold tracking-wide text-brand-text">
            {t.quickStart.eyebrow}
          </p>
          <h2
            id="quick-start-title"
            className="mt-2 text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
          >
            {t.quickStart.title}
          </h2>
          <p className="mt-4 text-lg leading-8 text-muted-foreground">
            {t.quickStart.intro}
          </p>
        </div>

        <Tabs defaultValue="docker" className="mt-10">
          <TabsList className="h-auto w-full max-w-xl">
            <TabsTrigger value="docker" className="px-3 py-2">
              {t.quickStart.tabs.docker}
            </TabsTrigger>
            <TabsTrigger value="local" className="px-3 py-2">
              {t.quickStart.tabs.local}
            </TabsTrigger>
            <TabsTrigger value="client" className="px-3 py-2">
              {t.quickStart.tabs.client}
            </TabsTrigger>
          </TabsList>
          {(["docker", "local", "client"] as const).map((tab) => (
            <TabsContent key={tab} value={tab} className="mt-4">
              <CodeBlock
                code={snippets[tab]}
                copyLabel={t.quickStart.copyLabel}
                copyTextLabel={t.quickStart.copy}
                copiedTextLabel={t.quickStart.copied}
                scrollLabel={t.quickStart.scrollLabel}
              />
            </TabsContent>
          ))}
        </Tabs>

        <p className="mt-5 text-sm text-muted-foreground">
          {t.quickStart.note}{" "}
          <a
            href={onboardingUrl}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1 rounded font-medium text-brand-text underline-offset-4 outline-none hover:underline focus-visible:ring-2 focus-visible:ring-ring"
          >
            {t.quickStart.noteLink}
            <ArrowUpRight className="size-3.5" aria-hidden="true" />
          </a>
        </p>
      </div>
    </section>
  )
}
