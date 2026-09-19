"use client";

import { useActionState, useState, useTransition } from "react";
import {
  loginAction,
  startTotpEnrollment,
  verifyTotpAction,
  verifyTotpEnrollment,
  type EnrollmentStart,
  type FormState,
} from "./actions";

const initial: FormState = {};

export function LoginForm({ next, notice }: { next: string; notice?: string }) {
  const [state, action, pending] = useActionState(loginAction, initial);
  return (
    <form action={action} className="form" noValidate>
      <input type="hidden" name="next" value={next} />
      {notice ? <p className="notice">{notice}</p> : null}
      <label>
        Email
        <input name="email" type="email" autoComplete="username" required />
      </label>
      <label>
        Kata sandi
        <input name="password" type="password" autoComplete="current-password" required />
      </label>
      {state.error ? (
        <p role="alert" className="error">
          {state.error}
        </p>
      ) : null}
      <button type="submit" disabled={pending}>
        {pending ? "Memeriksa…" : "Masuk"}
      </button>
    </form>
  );
}

/** Six-digit authenticator code, used for the sign-in challenge and for step-up re-verification. */
export function CodeForm({ next, submitLabel }: { next: string; submitLabel: string }) {
  const [state, action, pending] = useActionState(verifyTotpAction, initial);
  return (
    <form action={action} className="form" noValidate>
      <input type="hidden" name="next" value={next} />
      <label>
        Kode autentikator (6 digit)
        <input
          name="code"
          inputMode="numeric"
          autoComplete="one-time-code"
          pattern="[0-9]{6}"
          maxLength={6}
          required
        />
      </label>
      {state.error ? (
        <p role="alert" className="error">
          {state.error}
        </p>
      ) : null}
      <button type="submit" disabled={pending}>
        {pending ? "Memverifikasi…" : submitLabel}
      </button>
    </form>
  );
}

/** First-time TOTP enrollment: show QR, then confirm with a code. */
export function EnrollForm({ next }: { next: string }) {
  const [start, setStart] = useState<EnrollmentStart | null>(null);
  const [starting, startTransition] = useTransition();
  const [state, action, pending] = useActionState(verifyTotpEnrollment, initial);

  if (!start?.factorId) {
    return (
      <div className="form">
        <p className="hint">
          Akun ini wajib memakai autentikator (Google Authenticator, 1Password, dan sejenisnya).
        </p>
        {start?.error ? (
          <p role="alert" className="error">
            {start.error}
          </p>
        ) : null}
        <button
          type="button"
          disabled={starting}
          onClick={() => startTransition(async () => setStart(await startTotpEnrollment()))}
        >
          {starting ? "Menyiapkan…" : "Atur autentikator"}
        </button>
      </div>
    );
  }

  return (
    <form action={action} className="form" noValidate>
      <input type="hidden" name="next" value={next} />
      <input type="hidden" name="factorId" value={start.factorId} />
      {start.qrCode ? (
        // eslint-disable-next-line @next/next/no-img-element -- data: URI QR from Supabase, not optimizable
        <img
          className="qr"
          src={start.qrCode}
          alt="Kode QR autentikator"
          width={180}
          height={180}
        />
      ) : null}
      {start.secret ? (
        <p className="hint">
          Tidak bisa memindai? Masukkan kunci ini secara manual: <code>{start.secret}</code>
        </p>
      ) : null}
      <label>
        Kode dari autentikator (6 digit)
        <input
          name="code"
          inputMode="numeric"
          autoComplete="one-time-code"
          pattern="[0-9]{6}"
          maxLength={6}
          required
        />
      </label>
      {state.error ? (
        <p role="alert" className="error">
          {state.error}
        </p>
      ) : null}
      <button type="submit" disabled={pending}>
        {pending ? "Memverifikasi…" : "Aktifkan"}
      </button>
    </form>
  );
}
