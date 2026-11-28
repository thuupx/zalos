"use client"

import { Check, Copy } from "lucide-react"
import { useEffect, useRef, useState } from "react"

import { Button } from "@/components/ui/button"

async function copyText(text: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text)
    return
  }

  const textarea = document.createElement("textarea")
  textarea.value = text
  textarea.setAttribute("readonly", "")
  textarea.style.position = "fixed"
  textarea.style.opacity = "0"
  document.body.appendChild(textarea)
  textarea.select()
  const copied = document.execCommand("copy")
  textarea.remove()
  if (!copied) {
    throw new Error("Copy command failed")
  }
}

export function CodeBlock({
  code,
  copyLabel,
  copyTextLabel,
  copiedTextLabel,
  scrollLabel,
}: {
  code: string
  copyLabel: string
  copyTextLabel: string
  copiedTextLabel: string
  scrollLabel: string
}) {
  const [copied, setCopied] = useState(false)
  const timeoutRef = useRef<number | null>(null)

  useEffect(() => {
    return () => {
      if (timeoutRef.current !== null) {
        window.clearTimeout(timeoutRef.current)
      }
    }
  }, [])

  async function handleCopy() {
    try {
      await copyText(code)
      setCopied(true)
      if (timeoutRef.current !== null) {
        window.clearTimeout(timeoutRef.current)
      }
      timeoutRef.current = window.setTimeout(() => setCopied(false), 1600)
    } catch {
      setCopied(false)
    }
  }

  return (
    <div className="dark overflow-hidden rounded-2xl border border-border bg-card text-card-foreground shadow-lg">
      <div className="flex items-center justify-between border-b border-border px-4 py-2">
        <div className="flex gap-1.5" aria-hidden="true">
          <span className="size-2.5 rounded-full bg-brand" />
          <span className="size-2.5 rounded-full bg-gold" />
          <span className="size-2.5 rounded-full bg-success" />
        </div>
        <div aria-live="polite">
          <Button
            type="button"
            variant="ghost"
            size="sm"
            aria-label={copyLabel}
            onClick={handleCopy}
            className="text-muted-foreground hover:text-foreground"
          >
            {copied ? (
              <Check aria-hidden="true" />
            ) : (
              <Copy aria-hidden="true" />
            )}
            {copied ? copiedTextLabel : copyTextLabel}
          </Button>
        </div>
      </div>
      <div
        className="overflow-x-auto outline-none focus-visible:ring-2 focus-visible:ring-ring"
        tabIndex={0}
        aria-label={scrollLabel}
      >
        <pre className="min-w-max px-4 py-4 font-mono text-[13px] leading-6">
          <code>{code}</code>
        </pre>
      </div>
    </div>
  )
}
