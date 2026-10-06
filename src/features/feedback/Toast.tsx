"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { X } from "lucide-react";

export type ToastKind = "success" | "error" | "info";

interface ToastItem {
  id: number;
  kind: ToastKind;
  message: string;
}

interface ToastApi {
  show: (message: string, kind?: ToastKind) => void;
}

const NOOP: ToastApi = { show: () => undefined };
const ToastContext = createContext<ToastApi | null>(null);

/** Shows a notice in the corner of the screen. Outside the provider (tests, public pages) it does nothing. */
export function useToast(): ToastApi {
  return useContext(ToastContext) ?? NOOP;
}

/** Name of the cookie a redirecting server action leaves behind (`src/lib/flash.ts` writes it). */
const FLASH_COOKIE = "hf_flash";

/** Label of the button the person pressed last: "Berhasil: Simpan Nama & Profil" needs it. */
let lastSubmitLabel: string | null = null;
let lastSubmitter: HTMLElement | null = null;
export function getLastSubmitLabel(): string | null {
  return lastSubmitLabel;
}
/** The button that sent the last form: sending the same form again must name the same button. */
export function getLastSubmitter(): HTMLElement | null {
  return lastSubmitter;
}

const LIFETIME_MS: Record<ToastKind, number> = { success: 6000, info: 6000, error: 10000 };

function readFlash(): { kind: ToastKind; message: string } | null {
  try {
    const entry = document.cookie.split("; ").find((part) => part.startsWith(`${FLASH_COOKIE}=`));
    if (!entry) return null;
    document.cookie = `${FLASH_COOKIE}=; Max-Age=0; path=/`;
    const parsed = JSON.parse(decodeURIComponent(entry.slice(FLASH_COOKIE.length + 1))) as {
      kind?: string;
      message?: string;
    };
    if (typeof parsed.message !== "string" || parsed.message === "") return null;
    const kind: ToastKind =
      parsed.kind === "error" || parsed.kind === "info" ? parsed.kind : "success";
    return { kind, message: parsed.message };
  } catch {
    return null;
  }
}

/**
 * The notice host (OWNER, 6 October 2026: "pastikan selalu ada notifikasi setiap aksi"). Every server action
 * that answers with a result is announced here by `useActionState` (`./useActionState`), and an action that
 * redirects after success leaves a one-line cookie (`setFlash`) that is read here and shown once.
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const nextId = useRef(1);
  const recent = useRef(new Map<string, number>());

  const dismiss = useCallback((id: number) => {
    setItems((list) => list.filter((item) => item.id !== id));
  }, []);

  const show = useCallback(
    (message: string, kind: ToastKind = "success") => {
      const key = `${kind}:${message}`;
      const now = Date.now();
      const last = recent.current.get(key);
      // The same notice twice within a second is one event reported by two code paths.
      if (last !== undefined && now - last < 1000) return;
      recent.current.set(key, now);
      const id = nextId.current++;
      setItems((list) => [...list.slice(-3), { id, kind, message }]);
      window.setTimeout(() => dismiss(id), LIFETIME_MS[kind]);
    },
    [dismiss],
  );

  useEffect(() => {
    function onSubmit(event: Event) {
      const submitter = (event as SubmitEvent).submitter;
      const label = submitter?.textContent?.replace(/\s+/g, " ").trim() ?? "";
      lastSubmitLabel = label === "" ? null : label;
      lastSubmitter = submitter instanceof HTMLElement ? submitter : null;
    }
    document.addEventListener("submit", onSubmit, true);
    // A redirect swaps the page without a reload, so the cookie is simply checked twice a second.
    const timer = window.setInterval(() => {
      const flash = readFlash();
      if (flash) show(flash.message, flash.kind);
    }, 400);
    const first = readFlash();
    if (first) show(first.message, first.kind);
    return () => {
      document.removeEventListener("submit", onSubmit, true);
      window.clearInterval(timer);
    };
  }, [show]);

  const api = useMemo<ToastApi>(() => ({ show }), [show]);

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toast-region no-print" aria-live="polite">
        {items.map((item) => (
          <div
            key={item.id}
            className={`toast toast-${item.kind}`}
            role={item.kind === "error" ? "alert" : "status"}
          >
            <span className="toast-message">{item.message}</span>
            <button
              type="button"
              className="toast-close"
              aria-label="Tutup notifikasi"
              onClick={() => dismiss(item.id)}
            >
              <X size={16} strokeWidth={1.75} aria-hidden="true" />
            </button>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}
