"use client"

import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion"
import { useLocale } from "@/lib/i18n"

export function Faq() {
  const { t } = useLocale()

  return (
    <section
      id="faq"
      aria-labelledby="faq-title"
      className="scroll-mt-24 px-4 py-16 sm:px-6 sm:py-20 lg:px-8"
    >
      <div className="mx-auto max-w-[900px]">
        <div className="max-w-2xl">
          <p className="text-sm font-semibold tracking-wide text-brand-text">
            {t.faq.eyebrow}
          </p>
          <h2
            id="faq-title"
            className="mt-2 text-3xl font-semibold tracking-tight text-foreground sm:text-4xl"
          >
            {t.faq.title}
          </h2>
          <p className="mt-4 text-lg leading-8 text-muted-foreground">
            {t.faq.intro}
          </p>
        </div>

        <Accordion
          defaultValue={["item-0"]}
          className="mt-10 rounded-3xl border border-border bg-card px-5 shadow-sm"
        >
          {t.faq.items.map((item, index) => (
            <AccordionItem key={item.question} value={`item-${index}`}>
              <AccordionTrigger className="py-4 text-base font-semibold">
                {item.question}
              </AccordionTrigger>
              <AccordionContent className="pb-5 leading-7 text-muted-foreground">
                {item.answer}
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </div>
    </section>
  )
}
