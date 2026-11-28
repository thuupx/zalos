"use client"

import {
  Archive,
  Contact,
  HardDrive,
  ListChecks,
  MessageSquareText,
  MonitorSmartphone,
  Phone,
  Users,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { useLocale } from "@/lib/i18n"

const featureIcons = [
  Users,
  MonitorSmartphone,
  HardDrive,
  MessageSquareText,
  ListChecks,
  Phone,
  Contact,
  Archive,
]

export function Features() {
  const { t } = useLocale()

  return (
    <section
      id="features"
      aria-labelledby="features-title"
      className="scroll-mt-24 px-4 py-16 sm:px-6 sm:py-20 lg:px-8"
    >
      <div className="mx-auto max-w-[1200px]">
        <div className="max-w-2xl">
          <p className="text-sm font-semibold tracking-wide text-brand-text">
            {t.features.eyebrow}
          </p>
          <h2
            id="features-title"
            className="mt-2 text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
          >
            {t.features.title}
          </h2>
          <p className="mt-4 text-lg leading-8 text-muted-foreground">
            {t.features.intro}
          </p>
        </div>

        <div className="mt-10 grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          {t.features.items.map((item, index) => {
            const Icon = featureIcons[index] ?? MessageSquareText
            return (
              <Card
                key={item.title}
                className="rounded-2xl border-border shadow-sm transition-colors hover:border-brand/30"
              >
                <CardHeader>
                  <div className="mb-3 flex size-11 items-center justify-center rounded-xl bg-brand-subtle text-brand-text">
                    <Icon className="size-5" aria-hidden="true" />
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <CardTitle>
                      <h3 className="text-base font-medium leading-snug">
                        {item.title}
                      </h3>
                    </CardTitle>
                    {item.badge ? (
                      <Badge className="border-gold/30 bg-gold/15 text-gold-text">
                        {item.badge}
                      </Badge>
                    ) : null}
                  </div>
                </CardHeader>
                <CardContent>
                  <p className="leading-7 text-muted-foreground">
                    {item.description}
                  </p>
                </CardContent>
              </Card>
            )
          })}
        </div>
      </div>
    </section>
  )
}
