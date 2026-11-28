"use client"

import {
  ArrowUpRight,
  Globe,
  Laptop,
  Monitor,
  Smartphone,
  SquareTerminal,
} from "lucide-react"

import { ChatMockup } from "@/components/site/chat-mockup"
import { Button } from "@/components/ui/button"
import { useLocale } from "@/lib/i18n"

const platformIcons = [
  Smartphone,
  Smartphone,
  Laptop,
  Monitor,
  SquareTerminal,
  Globe,
]

export function Hero() {
  const { t } = useLocale()

  return (
    <section className="relative overflow-hidden px-4 py-16 sm:px-6 sm:py-20 lg:px-8 lg:py-24">
      <div className="mx-auto grid max-w-[1200px] items-center gap-12 lg:grid-cols-[1.05fr_0.95fr] lg:gap-16">
        <div className="max-w-2xl">
          <div className="inline-flex items-center gap-2 rounded-full border border-border bg-card px-3 py-1.5 text-sm font-medium text-muted-foreground shadow-sm">
            <span className="size-1.5 rounded-full bg-gold" />
            {t.hero.badge}
          </div>
          <h1 className="mt-6 text-balance text-4xl font-semibold tracking-tight text-foreground sm:text-5xl lg:text-6xl">
            {t.hero.title}
          </h1>
          <p className="mt-5 text-pretty text-lg leading-8 text-muted-foreground">
            {t.hero.subtitle}
          </p>
          <div className="mt-8 flex flex-col gap-3 sm:flex-row">
            <Button
              size="lg"
              className="h-11 rounded-full bg-brand px-5 hover:bg-brand-hover"
              render={<a href="#quick-start" />}
            >
              {t.hero.primaryCta}
            </Button>
            <Button
              variant="outline"
              size="lg"
              className="h-11 rounded-full px-5"
              render={
                <a href={t.links.repo} target="_blank" rel="noreferrer" />
              }
            >
              {t.hero.secondaryCta}
              <ArrowUpRight aria-hidden="true" />
            </Button>
          </div>
          <div className="mt-8 flex flex-wrap items-center gap-x-5 gap-y-3">
            {t.hero.platforms.map((platform, index) => {
              const Icon = platformIcons[index] ?? Globe
              return (
                <span
                  key={platform}
                  className="inline-flex items-center gap-1.5 text-xs font-medium text-muted-foreground"
                >
                  <Icon className="size-4" aria-hidden="true" />
                  {platform}
                </span>
              )
            })}
          </div>
        </div>
        <ChatMockup />
      </div>
    </section>
  )
}
