"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useTransition,
  type FormEvent,
  type ReactNode,
} from "react";
import { useRouter } from "next/navigation";
import { verifyStepUpAction } from "@/features/auth/actions";
import { getLastSubmitter, useToast } from "./Toast";

interface OpenOptions {
  /** Where the person was heading (the `next` of the old step-up link); the page is reloaded when it is here. */
  next: string | null;
  /** The form that was refused: submitted again once the code is accepted. */
  form: HTMLFormElement | null;
}

interface StepUpApi {
  open: (options: OpenOptions) => void;
}

const StepUpContext = createContext<StepUpApi | null>(null);

export function useStepUp(): StepUpApi {
  const context = useContext(StepUpContext);
  return context ?? { open: () => undefined };
}

/**
 * The re-verification popup (OWNER, 6 October 2026: "verifikasi kode dalam bentuk popup, supaya tidak perlu
 * berganti halaman"). Sensitive actions need a fresh authenticator code (30 minutes). Instead of sending the
 * person to `/auth/step-up`, the code is typed here; when it is accepted the popup closes, a notice says so,
 * and the refused form is submitted again (or the page is reloaded when there was no form), so the person
 * never leaves the page or loses what was typed. The database still decides: a wrong code stays in the popup
 * with an error, and a bypassed popup changes nothing.
 */
export function StepUpProvider({ children }: { children: ReactNode }) {
  const router = useRouter();
  const { show } = useToast();
  const [options, setOptions] = useState<OpenOptions | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [code, setCode] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  const open = useCallback((next: OpenOptions) => {
    setCode("");
    setError(null);
    setOptions(next);
  }, []);

  const close = useCallback(() => {
    setOptions(null);
    setError(null);
  }, []);

  useEffect(() => {
    if (!options) return;
    inputRef.current?.focus();
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") close();
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [options, close]);

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!options) return;
    const current = options;
    const trimmed = code.replace(/\s+/g, "");
    if (!/^[0-9]{6}$/.test(trimmed)) {
      setError("Masukkan 6 digit kode dari aplikasi autentikator.");
      return;
    }
    startTransition(async () => {
      const result = await verifyStepUpAction(trimmed);
      if (!result.ok) {
        setError(result.error ?? "Kode tidak sesuai atau sudah kedaluwarsa.");
        setCode("");
        inputRef.current?.focus();
        return;
      }
      close();
      show("Verifikasi berhasil.", "success");
      if (current.form && current.form.isConnected) {
        // The action that was refused is simply sent again, with everything the person had typed.
        const button = getLastSubmitter();
        const sameButton =
          button instanceof HTMLButtonElement || button instanceof HTMLInputElement
            ? button.form === current.form && button.isConnected
              ? button
              : undefined
            : undefined;
        current.form.requestSubmit(sameButton);
        return;
      }
      const here = `${window.location.pathname}${window.location.search}`;
      if (current.next && current.next !== here) router.push(current.next);
      else router.refresh();
    });
  }

  const api = useMemo<StepUpApi>(() => ({ open }), [open]);

  return (
    <StepUpContext.Provider value={api}>
      {children}
      {options ? (
        // Standard modal backdrop: Escape closes (handled above); a click on the dim area is only a mouse shortcut.
        // eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions
        <div className="modal-overlay no-print" onClick={close}>
          {/* eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-noninteractive-element-interactions */}
          <div
            className="modal-panel"
            role="dialog"
            aria-modal="true"
            aria-labelledby="stepup-title"
            onClick={(event) => event.stopPropagation()}
          >
            <h2 id="stepup-title">Verifikasi ulang</h2>
            <p className="hint">
              Tindakan ini memerlukan kode terbaru dari aplikasi autentikator Anda (berlaku 30
              menit).
            </p>
            <form onSubmit={submit} className="record-form" noValidate>
              <label>
                Kode autentikator (6 digit)
                <input
                  ref={inputRef}
                  name="code"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  pattern="[0-9]{6}"
                  maxLength={7}
                  value={code}
                  onChange={(event) => setCode(event.target.value)}
                  required
                />
              </label>
              {error ? (
                <p role="alert" className="error">
                  {error}
                </p>
              ) : null}
              <div className="modal-actions">
                <button type="button" className="btn-secondary" onClick={close} disabled={pending}>
                  Batal
                </button>
                <button type="submit" className="btn-primary" disabled={pending}>
                  {pending ? "Memverifikasi…" : "Verifikasi"}
                </button>
              </div>
            </form>
          </div>
        </div>
      ) : null}
    </StepUpContext.Provider>
  );
}

/** Reads the `next` of an old-style `/auth/step-up?next=...` address, or null. */
function nextOf(href: string): string | null {
  const query = href.indexOf("?");
  if (query < 0) return null;
  const next = new URLSearchParams(href.slice(query + 1)).get("next");
  return next && next.startsWith("/") && !next.startsWith("//") ? next : null;
}

/**
 * The replacement for every "Verifikasi sekarang" link: it opens the popup instead of leaving the page. Its
 * `href` stays the old step-up page, so it still works with scripts off or opened in a new tab. `auto` opens
 * the popup as soon as the link appears (use it where it is shown BECAUSE an action was just refused for want
 * of a fresh code); `retry={false}` reloads the page afterwards instead of submitting the surrounding form
 * again (for forms whose input cannot be sent twice, such as a chosen file).
 */
export function StepUpLink({
  href,
  auto = false,
  retry = true,
  children,
}: {
  href: string;
  auto?: boolean;
  retry?: boolean;
  children: ReactNode;
}) {
  const { open } = useStepUp();
  const ref = useRef<HTMLAnchorElement>(null);

  const launch = useCallback(() => {
    open({
      next: nextOf(href),
      form: retry ? (ref.current?.closest("form") ?? null) : null,
    });
  }, [open, href, retry]);

  useEffect(() => {
    if (auto) launch();
    // Once, when the link first appears.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <a
      ref={ref}
      href={href}
      onClick={(event) => {
        event.preventDefault();
        launch();
      }}
    >
      {children}
    </a>
  );
}
