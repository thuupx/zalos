"use client"

import { ArrowUpRight } from "lucide-react"

import { useLocale } from "@/lib/i18n"

export function CtaBand() {
  const { t } = useLocale()

  return (
    <section className="px-4 py-16 sm:px-6 sm:py-20 lg:px-8">
      <div className="mx-auto max-w-[1200px] rounded-3xl border border-border bg-gradient-to-r from-header-start to-header-end px-6 py-12 text-primary-foreground shadow-xl shadow-brand/10 sm:px-10 lg:px-12">
        <div className="flex flex-col gap-8 lg:flex-row lg:items-center lg:justify-between">
          <div className="max-w-2xl">
            <div className="mb-4 size-1.5 rounded-full bg-gold" />
            <h2 className="text-3xl font-semibold tracking-tight sm:text-4xl">
              {t.cta.title}
            </h2>
            <p className="mt-4 text-lg leading-8 text-primary-foreground/85">
              {t.cta.body}
            </p>
          </div>
          <div className="flex flex-col gap-3 sm:flex-row lg:shrink-0">
            <a
              href="#quick-start"
              className="inline-flex h-11 items-center justify-center rounded-full bg-primary-foreground px-5 text-sm font-semibold text-primary transition-colors outline-none hover:bg-primary-foreground/90 focus-visible:ring-3 focus-visible:ring-primary-foreground/70"
            >
              {t.cta.primary}
            </a>
            <a
              href={t.links.repo}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-11 items-center justify-center gap-1.5 rounded-full border border-primary-foreground/40 px-5 text-sm font-semibold text-primary-foreground transition-colors outline-none hover:bg-primary-foreground/10 focus-visible:ring-3 focus-visible:ring-primary-foreground/70"
            >
              {t.cta.secondary}
              <ArrowUpRight className="size-4" aria-hidden="true" />
            </a>
          </div>
        </div>
      </div>
    </section>
  )
}
