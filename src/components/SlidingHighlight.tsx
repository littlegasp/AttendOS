"use client";

import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState } from "react";

/**
 * A highlight that glides to the selected item inside its parent (the menu,
 * Board/Table, date ranges) instead of jumping. `selector` picks the selected item.
 */
export function SlidingHighlight({ selector, className = "" }: { selector: string; className?: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const path = usePathname();
  const params = useSearchParams();
  const [box, setBox] = useState<{ x: number; y: number; w: number; h: number } | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const host = ref.current?.parentElement;
    if (!host) return;
    const place = () => {
      const on = host.querySelector<HTMLElement>(selector);
      if (!on) return setBox(null);
      setBox({ x: on.offsetLeft, y: on.offsetTop, w: on.offsetWidth, h: on.offsetHeight });
    };
    place();
    // Allow transitions only after the first placement, so it doesn't fly in from the corner.
    const t = setTimeout(() => setReady(true), 50);
    const ro = new ResizeObserver(place);
    ro.observe(host);
    const mo = new MutationObserver(place);
    mo.observe(host, { subtree: true, attributes: true, attributeFilter: ["class", "aria-current"] });
    return () => {
      clearTimeout(t);
      ro.disconnect();
      mo.disconnect();
    };
  }, [selector, path, params]);

  return (
    <span
      ref={ref}
      aria-hidden="true"
      className={`slide-hl ${className}${ready ? " ready" : ""}`}
      style={box ? { transform: `translate(${box.x}px, ${box.y}px)`, width: box.w, height: box.h, opacity: 1 } : { opacity: 0 }}
    />
  );
}
