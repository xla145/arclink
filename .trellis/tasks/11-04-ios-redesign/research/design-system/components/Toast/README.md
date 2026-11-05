Toasts confirm a finished action briefly; banners report a problem you can act on.

**Toast** — an `ink` capsule with `bg` text, `shadow-float`, bottom-centre above the home indicator, two seconds. Use for 已复制, 已配对, 已删除.

**Banner** — inline, `danger-soft` with `danger` text and an alert icon, `radius-md`, plus a 重试 button when retrying makes sense. Use for send failures, lost connections and wrong QR codes; it stays until resolved.

Consumer provides the message (one short sentence, no trailing period) and, for banners, the action.
