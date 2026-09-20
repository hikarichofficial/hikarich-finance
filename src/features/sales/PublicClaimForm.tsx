"use client";

import { useActionState } from "react";
import { submitClaimAction, type ClaimState, type ClaimStatus } from "./publicActions";

const initial: ClaimState = { status: "idle" };

const MESSAGES: Partial<Record<ClaimStatus, string>> = {
  received:
    "Terima kasih. Konfirmasi Anda sudah kami terima dan akan diperiksa. Faktur baru dinyatakan lunas setelah pembayaran kami verifikasi.",
  already_received:
    "Konfirmasi yang sama sudah kami terima sebelumnya dan sedang diperiksa. Anda tidak perlu mengirim ulang.",
  unavailable: "Tautan ini tidak lagi berlaku.",
  throttled: "Terlalu banyak permintaan. Silakan coba lagi nanti.",
  conflict: "Faktur ini sudah lunas atau tidak lagi menerima pembayaran.",
  invalid:
    "Data belum sesuai. Periksa jumlah (tidak boleh melebihi sisa tagihan) dan tanggal pembayaran (antara tanggal faktur dan hari ini).",
};

export function PublicClaimForm({
  token,
  today,
  minDate,
  outstanding,
}: {
  token: string;
  today: string;
  minDate: string;
  outstanding: string;
}) {
  const [state, action, pending] = useActionState(submitClaimAction, initial);
  const done = state.status === "received" || state.status === "already_received";
  const message = MESSAGES[state.status];

  if (done) {
    return (
      <p role="status" className="notice">
        {message}
      </p>
    );
  }

  return (
    <form action={action} className="form claim" noValidate>
      <input type="hidden" name="token" value={token} />
      <p className="hint">
        Sudah membayar? Beri tahu kami. Ini hanya konfirmasi; kami tetap memeriksa pembayaran yang
        masuk sebelum faktur dinyatakan lunas.
      </p>
      <label>
        Jumlah yang dibayar
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          defaultValue={outstanding}
          required
        />
      </label>
      <label>
        Tanggal pembayaran
        <input
          name="payment_date"
          type="date"
          min={minDate}
          max={today}
          defaultValue={today}
          required
        />
      </label>
      <label>
        Nama pembayar (opsional)
        <input name="payer_name" maxLength={200} autoComplete="name" />
      </label>
      <label>
        Nomor referensi transfer (opsional)
        <input name="reference" maxLength={200} autoComplete="off" />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={1000} autoComplete="off" />
      </label>
      {message ? (
        <p role="alert" className="error">
          {message}
        </p>
      ) : null}
      <button type="submit" disabled={pending}>
        {pending ? "Mengirim…" : "Saya Sudah Bayar"}
      </button>
    </form>
  );
}
