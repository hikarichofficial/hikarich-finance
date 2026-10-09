"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { createPathMemory } from "@/domain/shell/backNavigation";

/** One memory for the whole tab, shared by the tracker below and every BackLink. */
export const pathMemory = createPathMemory();

/** Mounted once in the application shell: records each page the person opens, so "← Kembali" can go back to it. */
export function PathMemoryTracker() {
  const pathname = usePathname();
  useEffect(() => {
    pathMemory.visit(pathname);
  }, [pathname]);
  return null;
}
