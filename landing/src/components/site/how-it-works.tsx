"use client"

import {
  ArrowRight,
  Globe,
  LockKeyhole,
  MonitorSmartphone,
  Server,
} from "lucide-react"

import { useLocale } from "@/lib/i18n"

function ArchitectureBox({
  icon: Icon,
  label,
}: {
  icon: typeof MonitorSmartphone
  label: string
}) {
  return (
    <div className="flex min-w-0 flex-1 items-center justify-center gap-2 rounded-2xl border border-border bg-card px-4 py-3 text-center shadow-sm">
      <Icon className="size-4 shrink-0 text-brand-text" aria-hidden="true" />
      <span className="text-sm font-medium text-foreground">{label}</span>
    </div>
  )
}

function ArchitectureArrow() {
  return (
    <ArrowRight
      className="mx-auto size-4 shrink-0 rotate-90 text-muted-foreground md:rotate-0"
      aria-hidden="true"
    />
  )
}

export function HowItWorks() {
  const { t } = useLocale()

  return (
    <section
      id="how-it-works"
      aria-labelledby="how-it-works-title"
      className="scroll-mt-24 px-4 py-16 sm:px-6 sm:py-20 lg:px-8"
    >
      <div className="mx-auto max-w-[1200px]">
        <div className="max-w-2xl">
          <p className="text-sm font-semibold tracking-wide text-brand-text">
            {t.howItWorks.eyebrow}
          </p>
          <h2
            id="how-it-works-title"
            className="mt-2 text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
          >
            {t.howItWorks.title}
          </h2>
          <p className="mt-4 text-lg leading-8 text-muted-foreground">
            {t.howItWorks.intro}
          </p>
        </div>

        <ol className="mt-10 grid gap-4 md:grid-cols-3">
          {t.howItWorks.steps.map((step, index) => (
            <li
              key={step.title}
              className="rounded-2xl border border-border bg-card p-5 shadow-sm"
            >
              <div className="flex size-9 items-center justify-center rounded-full bg-brand text-sm font-semibold text-primary-foreground">
                {index + 1}
              </div>
              <h3 className="mt-4 text-lg font-semibold text-foreground">
                {step.title}
              </h3>
              <p className="mt-2 leading-7 text-muted-foreground">
                {step.description}
              </p>
            </li>
          ))}
        </ol>

        <div className="mt-10 rounded-3xl border border-border bg-muted p-4 sm:p-5">
          <h3 className="px-1 text-sm font-semibold tracking-wide text-muted-foreground">
            {t.howItWorks.architectureTitle}
          </h3>
          <div className="mt-4 flex flex-col items-stretch gap-3 md:flex-row md:items-center">
            <ArchitectureBox
              icon={MonitorSmartphone}
              label={t.howItWorks.architecture.clients}
            />
            <ArchitectureArrow />
            <ArchitectureBox
              icon={LockKeyhole}
              label={t.howItWorks.architecture.transport}
            />
            <ArchitectureArrow />
            <ArchitectureBox
              icon={Server}
              label={t.howItWorks.architecture.server}
            />
            <ArchitectureArrow />
            <ArchitectureBox
              icon={Globe}
              label={t.howItWorks.architecture.zalo}
            />
          </div>
        </div>
      </div>
    </section>
  )
}
