"use client";

import { useActionState as reactUseActionState, useEffect, useRef } from "react";
import { authzErrorMessage } from "@/domain/authz/errors";
import { useStepUp } from "./StepUp";
import { getLastSubmitLabel, getLastSubmitter, useToast } from "./Toast";

/**
 * Drop-in replacement for React's `useActionState` that also announces the result as a notice
 * (OWNER, 6 October 2026: "pastikan selalu ada notifikasi setiap aksi, perubahan atau sejenisnya").
 *
 * Every action state in this codebase is `{ status: "idle" | "ok" | "error"; message?: string; stepUp?: boolean }`:
 * `ok` shows the action's own message, or "Berhasil: <the button pressed>" when it has none; `error` shows the
 * message (never silent). A refused action that only needs a fresh code (`stepUp`, or the database's own
 * "verifikasi ulang" copy) is not announced as a failure: the verification popup opens instead, and the form
 * is sent again once the code is accepted. States without a `status` (the sign-in forms) are left alone.
 */
export function useActionState<State>(
  action: (state: Awaited<State>) => State | Promise<State>,
  initialState: Awaited<State>,
  permalink?: string,
): [state: Awaited<State>, dispatch: () => void, isPending: boolean];
export function useActionState<State, Payload>(
  action: (state: Awaited<State>, payload: Payload) => State | Promise<State>,
  initialState: Awaited<State>,
  permalink?: string,
): [state: Awaited<State>, dispatch: (payload: Payload) => void, isPending: boolean];
export function useActionState<State, Payload>(
  action: (state: Awaited<State>, payload: Payload) => State | Promise<State>,
  initialState: Awaited<State>,
  permalink?: string,
) {
  const result = reactUseActionState(action, initialState, permalink);
  const state = result[0];
  const { show } = useToast();
  const stepUpPopup = useStepUp();
  const seen = useRef<unknown>(state);

  useEffect(() => {
    if (seen.current === state) return;
    seen.current = state;
    if (typeof state !== "object" || state === null) return;
    const { status, message, stepUp } = state as {
      status?: unknown;
      message?: unknown;
      stepUp?: unknown;
    };
    const text = typeof message === "string" && message.trim() !== "" ? message : null;
    if (stepUp === true || (status === "error" && text === authzErrorMessage("STEP_UP_REQUIRED"))) {
      const button = getLastSubmitter();
      stepUpPopup.open({
        next: null,
        form:
          button instanceof HTMLButtonElement || button instanceof HTMLInputElement
            ? button.form
            : null,
      });
      return;
    }
    if (status === "ok") {
      const label = getLastSubmitLabel();
      show(text ?? (label ? `Berhasil: ${label}` : "Berhasil disimpan."), "success");
    } else if (status === "error") {
      show(text ?? "Aksi tidak berhasil. Periksa isian lalu coba lagi.", "error");
    }
  }, [state, show, stepUpPopup]);

  return result;
}
