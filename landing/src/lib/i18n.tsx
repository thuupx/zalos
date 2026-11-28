"use client"

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useSyncExternalStore,
} from "react"

import { site, type SiteCopy } from "@/content/site"

type Locale = keyof typeof site

type LocaleContextValue = {
  locale: Locale
  setLocale: (locale: Locale) => void
  t: SiteCopy
}

const LocaleContext = createContext<LocaleContextValue | null>(null)
const listeners = new Set<() => void>()
let currentLocale: Locale | null = null

function detectInitialLocale(): Locale {
  if (typeof window === "undefined") {
    return "vi"
  }
  const stored = window.localStorage.getItem("zalos-locale")
  if (stored === "vi" || stored === "en") {
    return stored
  }
  return window.navigator.language.toLowerCase().startsWith("en") ? "en" : "vi"
}

function getSnapshot(): Locale {
  currentLocale ??= detectInitialLocale()
  return currentLocale
}

function getServerSnapshot(): Locale {
  return "vi"
}

function emitChange() {
  listeners.forEach((listener) => listener())
}

function subscribe(listener: () => void) {
  listeners.add(listener)

  function onStorage(event: StorageEvent) {
    if (
      event.key === "zalos-locale" &&
      (event.newValue === "vi" || event.newValue === "en")
    ) {
      currentLocale = event.newValue
      emitChange()
    }
  }

  window.addEventListener("storage", onStorage)
  return () => {
    listeners.delete(listener)
    window.removeEventListener("storage", onStorage)
  }
}

export function LocaleProvider({ children }: { children: React.ReactNode }) {
  const locale = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot)

  useEffect(() => {
    document.documentElement.lang = locale
  }, [locale])

  const setLocale = useCallback((nextLocale: Locale) => {
    currentLocale = nextLocale
    window.localStorage.setItem("zalos-locale", nextLocale)
    emitChange()
  }, [])

  const value = useMemo(
    () => ({ locale, setLocale, t: site[locale] }),
    [locale, setLocale]
  )

  return (
    <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>
  )
}

export function useLocale() {
  const context = useContext(LocaleContext)
  if (!context) {
    throw new Error("useLocale must be used inside LocaleProvider")
  }
  return context
}
