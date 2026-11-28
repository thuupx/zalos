"use client"

import { ArrowUpRight } from "lucide-react"

import { useLocale } from "@/lib/i18n"

export function Security() {
  const { t } = useLocale()

  return (
    <section
      id="security"
      aria-labelledby="security-title"
      className="scroll-mt-24 px-4 py-16 sm:px-6 sm:py-20 lg:px-8"
    >
      <div className="dark mx-auto max-w-[1200px] rounded-3xl border border-border bg-background text-foreground shadow-xl shadow-brand/10">
        <div className="grid gap-10 p-6 sm:p-8 lg:grid-cols-[0.8fr_1.2fr] lg:p-10">
          <div>
            <p className="text-sm font-semibold tracking-wide text-brand-text">
              {t.security.eyebrow}
            </p>
            <h2
              id="security-title"
              className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl"
            >
              {t.security.title}
            </h2>
            <p className="mt-4 text-lg leading-8 text-muted-foreground">
              {t.security.intro}
            </p>
            <a
              href={t.links.security}
              target="_blank"
              rel="noreferrer"
              className="mt-6 inline-flex items-center gap-1.5 rounded-lg text-sm font-semibold text-gold underline-offset-4 outline-none hover:underline focus-visible:ring-2 focus-visible:ring-ring"
            >
              {t.security.linkLabel}
              <ArrowUpRight className="size-4" aria-hidden="true" />
            </a>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            {t.security.points.map((point) => (
              <article
                key={point.title}
                className="rounded-2xl border border-border bg-card p-5"
              >
                <code className="inline-flex max-w-full rounded-md bg-accent px-2 py-1 font-mono text-xs text-accent-foreground">
                  {point.chip}
                </code>
                <h3 className="mt-4 text-base font-semibold">
                  {point.title}
                </h3>
                <p className="mt-2 text-sm leading-6 text-muted-foreground">
                  {point.description}
                </p>
              </article>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}
