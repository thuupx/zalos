"use client"

import {
  Heart,
  Mic,
  Paperclip,
  Pin,
  Search,
  Send,
} from "lucide-react"

import { useLocale } from "@/lib/i18n"
import { cn } from "@/lib/utils"

export function ChatMockup() {
  const { t } = useLocale()
  const mockup = t.hero.mockup

  return (
    <div className="relative">
      <div
        aria-hidden="true"
        className="absolute inset-10 rounded-full bg-brand/20 blur-3xl"
      />
      <div
        aria-hidden="true"
        className="relative mx-auto w-full max-w-[430px] overflow-hidden rounded-[2rem] border border-border bg-card shadow-xl shadow-brand/10"
      >
        <div className="bg-gradient-to-r from-header-start to-header-end px-5 py-4 text-primary-foreground">
          <div className="flex items-center gap-3">
            <div className="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary-foreground/15 text-base font-bold">
              {mockup.groupName.slice(0, 1)}
            </div>
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-semibold">
                {mockup.groupName}
              </div>
              <div className="mt-0.5 flex items-center gap-1.5 text-xs text-primary-foreground/80">
                <span className="size-1.5 rounded-full bg-success" />
                {mockup.devices}
              </div>
            </div>
            <Search className="size-4 text-primary-foreground/80" />
          </div>
        </div>

        <div className="flex items-center gap-2 border-b border-border bg-gold/15 px-4 py-2 text-xs font-medium text-gold-text">
          <Pin className="size-3.5" />
          <span className="truncate">{mockup.pinned}</span>
        </div>

        <div className="flex flex-col gap-3 bg-surface px-4 py-5">
          {mockup.messages.map((message, index) => (
            <div
              key={`${message.time}-${index}`}
              className={cn(
                "max-w-[84%] rounded-2xl border px-3 py-2 text-sm shadow-sm",
                message.side === "out"
                  ? "ml-auto rounded-br-md border-bubble-out-border bg-bubble-out"
                  : "rounded-bl-md border-bubble-in-border bg-bubble-in"
              )}
            >
              <p className="leading-snug">{message.text}</p>
              <div className="mt-1 flex items-center justify-end gap-2">
                {message.reaction ? (
                  <span className="inline-flex items-center gap-1 rounded-full border border-border bg-card px-1.5 py-0.5 text-[11px] font-medium text-brand-text">
                    <Heart className="size-3" fill="currentColor" />
                    {message.reaction}
                  </span>
                ) : null}
                <span className="text-[11px] text-muted-foreground">
                  {message.time}
                </span>
              </div>
            </div>
          ))}
        </div>

        <div className="flex items-center gap-2 border-t border-border bg-card px-4 py-3">
          <Paperclip className="size-4 shrink-0 text-muted-foreground" />
          <div className="min-w-0 flex-1 truncate rounded-full border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
            {mockup.composerPlaceholder}
          </div>
          <Mic className="size-4 shrink-0 text-muted-foreground" />
          <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-brand text-primary-foreground">
            <Send className="size-4" />
          </div>
        </div>
      </div>
      <p className="sr-only">{mockup.caption}</p>
    </div>
  )
}
