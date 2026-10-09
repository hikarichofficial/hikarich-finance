"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import type { ComponentProps, MouseEvent } from "react";
import { shouldGoBackInHistory } from "@/domain/shell/backNavigation";
import { pathMemory } from "./PathMemory";

/**
 * "← Kembali ke …" on a record page. It keeps its fixed list as `href` (so it still works when opened in a new tab,
 * from a bookmark, or before the page's scripts have loaded), but a plain click goes back to the page the person was
 * on before (see `backNavigation.ts`). A click with a modifier key (new tab, new window) keeps the normal link.
 */
export function BackLink({ href, onClick, children, ...rest }: ComponentProps<typeof Link>) {
  const router = useRouter();

  function handleClick(event: MouseEvent<HTMLAnchorElement>) {
    onClick?.(event);
    if (event.defaultPrevented) return;
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
      return;
    if (shouldGoBackInHistory(pathMemory.previous, pathMemory.current ?? "")) {
      event.preventDefault();
      router.back();
    }
  }

  return (
    <Link href={href} onClick={handleClick} {...rest}>
      {children}
    </Link>
  );
}
