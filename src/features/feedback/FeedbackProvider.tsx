"use client";

import type { ReactNode } from "react";
import { StepUpProvider } from "./StepUp";
import { ToastProvider } from "./Toast";

/** Notices and the re-verification popup, available on every page (mounted once in the root layout). */
export function FeedbackProvider({ children }: { children: ReactNode }) {
  return (
    <ToastProvider>
      <StepUpProvider>{children}</StepUpProvider>
    </ToastProvider>
  );
}
