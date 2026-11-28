"use client"

import {
  GitBranch,
  Menu,
  Moon,
  Sun,
} from "lucide-react"
import Image from "next/image"
import { useTheme } from "next-themes"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet"
import { useLocale } from "@/lib/i18n"
import { cn } from "@/lib/utils"

const navItems = [
  { id: "features", key: "features" },
  { id: "how-it-works", key: "howItWorks" },
  { id: "security", key: "security" },
  { id: "quick-start", key: "quickStart" },
  { id: "faq", key: "faq" },
] as const

function sectionHref(id: string) {
  return `#${id}`
}

function LanguageToggle() {
  const { locale, setLocale, t } = useLocale()

  return (
    <div
      role="group"
      aria-label={t.controls.languageLabel}
      className="flex items-center rounded-full border border-border bg-muted p-0.5"
    >
      {(["vi", "en"] as const).map((item) => (
        <button
          key={item}
          type="button"
          aria-pressed={locale === item}
          onClick={() => setLocale(item)}
          className={cn(
            "rounded-full px-2.5 py-1 text-xs font-semibold tracking-wide transition-colors outline-none focus-visible:ring-2 focus-visible:ring-ring",
            locale === item
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:text-foreground"
          )}
        >
          {item.toUpperCase()}
        </button>
      ))}
    </div>
  )
}

function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme()
  const { t } = useLocale()

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      aria-label={t.controls.themeToggle}
      onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
    >
      <Sun className="hidden dark:block" aria-hidden="true" />
      <Moon className="dark:hidden" aria-hidden="true" />
    </Button>
  )
}

function Brand() {
  return (
    <a
      href="#content"
      className="flex items-center gap-2 rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <Image
        src="/brand/zalos-mark.svg"
        width={39}
        height={32}
        alt=""
        aria-hidden="true"
        priority
        className="h-8 w-auto"
      />
      <span className="text-xl font-bold tracking-tight text-brand-text">
        zalos
      </span>
    </a>
  )
}

function GithubButton() {
  const { t } = useLocale()

  return (
    <Button
      variant="outline"
      size="sm"
      render={
        <a
          href={t.links.repo}
          target="_blank"
          rel="noreferrer"
          aria-label={t.controls.githubLabel}
        />
      }
    >
      <GitBranch aria-hidden="true" />
      {t.nav.github}
    </Button>
  )
}

export function SiteHeader() {
  const { t } = useLocale()
  const [menuOpen, setMenuOpen] = useState(false)

  return (
    <>
      <a
        href="#content"
        className="sr-only z-[60] rounded-full bg-primary px-4 py-2 text-sm font-medium text-primary-foreground focus:not-sr-only focus:fixed focus:top-3 focus:left-3"
      >
        {t.nav.skipToContent}
      </a>
      <header className="sticky top-0 z-50 border-b border-border bg-background/80 backdrop-blur">
        <div className="mx-auto flex h-16 max-w-[1200px] items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <Brand />

          <nav
            aria-label={t.nav.ariaLabel}
            className="hidden items-center gap-1 md:flex"
          >
            {navItems.map((item) => (
              <a
                key={item.id}
                href={sectionHref(item.id)}
                className="rounded-lg px-3 py-2 text-sm font-medium text-muted-foreground transition-colors outline-none hover:bg-muted hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
              >
                {t.nav[item.key]}
              </a>
            ))}
          </nav>

          <div className="hidden items-center gap-2 md:flex">
            <LanguageToggle />
            <ThemeToggle />
            <GithubButton />
          </div>

          <div className="md:hidden">
            <Sheet open={menuOpen} onOpenChange={setMenuOpen}>
              <SheetTrigger
                render={
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label={t.nav.openMenu}
                  />
                }
              >
                <Menu aria-hidden="true" />
              </SheetTrigger>
              <SheetContent className="w-[86vw] max-w-sm gap-0 p-0">
                <SheetHeader className="border-b border-border">
                  <SheetTitle>{t.nav.mobileMenuTitle}</SheetTitle>
                </SheetHeader>
                <nav
                  aria-label={t.nav.ariaLabel}
                  className="flex flex-col gap-1 p-4"
                >
                  {navItems.map((item) => (
                    <a
                      key={item.id}
                      href={sectionHref(item.id)}
                      onClick={() => setMenuOpen(false)}
                      className="rounded-xl px-3 py-3 text-base font-medium text-foreground transition-colors outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring"
                    >
                      {t.nav[item.key]}
                    </a>
                  ))}
                </nav>
                <div className="mt-auto flex flex-col gap-4 border-t border-border p-4">
                  <div className="flex items-center justify-between gap-3">
                    <LanguageToggle />
                    <ThemeToggle />
                  </div>
                  <GithubButton />
                </div>
              </SheetContent>
            </Sheet>
          </div>
        </div>
      </header>
    </>
  )
}
