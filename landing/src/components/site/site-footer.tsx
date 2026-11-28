"use client"

import Image from "next/image"

import { useLocale } from "@/lib/i18n"

export function SiteFooter() {
  const { t } = useLocale()
  const links = [
    { href: t.links.repo, label: t.footer.github },
    { href: t.links.onboardingVi, label: t.footer.onboardingVi },
    { href: t.links.onboardingEn, label: t.footer.onboardingEn },
    { href: t.links.security, label: t.footer.security },
  ]

  return (
    <footer className="border-t border-border px-4 py-10 sm:px-6 lg:px-8">
      <div className="mx-auto flex max-w-[1200px] flex-col gap-8 md:flex-row md:items-start md:justify-between">
        <div className="max-w-sm">
          <div className="flex items-center gap-2">
            <Image
              src="/brand/zalos-mark.svg"
              width={31}
              height={26}
              alt=""
              aria-hidden="true"
              className="h-7 w-auto"
            />
            <span className="text-lg font-bold tracking-tight text-brand-text">
              zalos
            </span>
          </div>
          <p className="mt-3 text-sm leading-6 text-muted-foreground">
            {t.footer.description}
          </p>
        </div>

        <nav
          aria-label={t.footer.navLabel}
          className="flex flex-col gap-3 text-sm sm:flex-row sm:flex-wrap sm:gap-x-6"
        >
          {links.map((link) => (
            <a
              key={link.href + link.label}
              href={link.href}
              target="_blank"
              rel="noreferrer"
              className="rounded font-medium text-muted-foreground underline-offset-4 outline-none transition-colors hover:text-foreground hover:underline focus-visible:ring-2 focus-visible:ring-ring"
            >
              {link.label}
            </a>
          ))}
        </nav>
      </div>
      <div className="mx-auto mt-8 max-w-[1200px] border-t border-border pt-6">
        <p className="text-xs leading-5 text-muted-foreground">
          {t.footer.disclaimer}
        </p>
      </div>
    </footer>
  )
}
