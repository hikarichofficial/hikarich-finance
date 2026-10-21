"use client";

import { useTransition } from "react";
import { formatRupiah } from "@/domain/telegram/rupiah";
import { useActionState } from "@/features/feedback/useActionState";
import { useToast } from "@/features/feedback/Toast";
import { PageHelp } from "@/features/shared/PageHelp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import type { BotStatus } from "@/services/telegram/status";
import type { TelegramLink } from "@/services/telegram/link";
import {
  createCodeAction,
  registerWebhookAction,
  revokeLinkAction,
  saveSettingsAction,
  type TelegramActionState,
} from "./actions";
import { idleTelegramState } from "./actionState";

/**
 * Telegram bot settings (decision 422). Shows whether the server side is ready, pairs the owner's Telegram account with
 * a one-time code, and holds the limit and the automatic reports. Everything sensitive is decided by the database
 * under the owner's own session (MFA and a fresh step-up).
 */

function Row({ label, ok, detail }: { label: string; ok: boolean; detail?: string }) {
  return (
    <li>
      <span aria-hidden="true">{ok ? "✅" : "⚪"}</span> {label}
      {detail ? <span className="hint"> — {detail}</span> : null}
    </li>
  );
}

function CodeBox({ botUsername }: { botUsername: string | null }) {
  const [state, action, pending] = useActionState(createCodeAction, idleTelegramState);
  return (
    <div className="record-form">
      <p>
        Buat kode sekali pakai (berlaku 10 menit), lalu kirim <code>/start KODE</code> ke bot
        {botUsername ? (
          <>
            {" "}
            <strong>@{botUsername}</strong>
          </>
        ) : null}{" "}
        di Telegram. Membuat kode meminta kode autentikator.
      </p>
      <form action={action}>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Membuat…" : "Buat Kode Penghubung"}
        </button>
      </form>
      {state.status === "ok" && state.code ? (
        <p role="status">
          Kode Anda:{" "}
          <code style={{ fontSize: "1.4em", letterSpacing: "0.15em" }}>{state.code}</code>
          <br />
          Kirim: <code>/start {state.code}</code>
        </p>
      ) : null}
    </div>
  );
}

function SettingsForm({ link }: { link: Extract<TelegramLink, { linked: true }> }) {
  const [state, action, pending] = useActionState(saveSettingsAction, idleTelegramState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="record-form">
      <label>
        Batas nominal per catatan dari bot (Rp)
        <input
          name="max_entry_amount"
          inputMode="numeric"
          required
          defaultValue={String(Math.round(Number(link.max_entry_amount)))}
        />
        <span className="hint">
          Sekarang {formatRupiah(Number(link.max_entry_amount))}. Di atas batas, catatan hanya jadi
          draf untuk Anda konfirmasi di website. Menaikkan batas meminta kode autentikator.
        </span>
      </label>
      <label>
        <input type="checkbox" name="report_daily" defaultChecked={link.report_daily} /> Laporan
        harian (sekitar 21.00 WITA)
      </label>
      <label>
        <input type="checkbox" name="report_weekly" defaultChecked={link.report_weekly} /> Laporan
        mingguan (Senin sekitar 08.00 WITA, minggu sebelumnya)
      </label>
      <label>
        <input type="checkbox" name="report_monthly" defaultChecked={link.report_monthly} /> Laporan
        bulanan (tanggal 1 sekitar 08.00 WITA, bulan sebelumnya)
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Pengaturan"}
      </button>
    </form>
  );
}

function ActionButton({
  label,
  busy,
  run,
  className,
}: {
  label: string;
  busy: string;
  run: () => Promise<TelegramActionState>;
  className: string;
}) {
  const { show } = useToast();
  const [pending, start] = useTransition();
  return (
    <button
      type="button"
      className={className}
      disabled={pending}
      onClick={() =>
        start(async () => {
          const result = await run();
          show(
            result.message ?? (result.status === "ok" ? "Berhasil." : "Gagal."),
            result.status === "ok" ? "success" : "error",
          );
        })
      }
    >
      {pending ? busy : label}
    </button>
  );
}

export function TelegramScreen({ status, link }: { status: BotStatus; link: TelegramLink }) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Bot Telegram</h1>
          <PageHelp />
        </div>
      </header>

      <section className="card">
        <h2>Status server</h2>
        <ul>
          <Row
            label="Bot dan penyimpanan"
            ok={status.configured}
            detail={
              status.configured
                ? status.botUsername
                  ? `@${status.botUsername}`
                  : undefined
                : "isi TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, SUPABASE_SERVICE_ROLE_KEY di Vercel"
            }
          />
          <Row
            label="Webhook terdaftar"
            ok={Boolean(status.webhookUrl)}
            detail={status.lastError ?? (status.webhookUrl ? undefined : "tekan Daftarkan Webhook")}
          />
          <Row
            label="AI Gemini (baca struk & pesan bebas)"
            ok={status.aiConfigured}
            detail={status.aiConfigured ? undefined : "opsional: isi GEMINI_API_KEY"}
          />
          <Row
            label="Laporan otomatis (jadwal)"
            ok={status.cronConfigured}
            detail={status.cronConfigured ? undefined : "isi CRON_SECRET di Vercel"}
          />
        </ul>
        <ActionButton
          label="Daftarkan Webhook"
          busy="Mendaftarkan…"
          run={registerWebhookAction}
          className="btn-secondary"
        />
      </section>

      <section className="card">
        <h2>Akun Telegram Anda</h2>
        {link.linked ? (
          <>
            <p>
              Terhubung
              {link.telegram_username ? (
                <>
                  {" "}
                  sebagai <strong>@{link.telegram_username}</strong>
                </>
              ) : null}{" "}
              sejak {link.linked_at.slice(0, 10)}.
            </p>
            {link.groups.length > 0 ? (
              <p>Grup: {link.groups.map((g) => g.title ?? g.chat_id).join(", ")}</p>
            ) : (
              <p className="hint">
                Belum ada grup. Tambahkan bot ke grup lalu ketik /daftargrup di sana.
              </p>
            )}
            <ActionButton
              label="Putuskan Telegram"
              busy="Memutuskan…"
              run={revokeLinkAction}
              className="btn-danger"
            />
          </>
        ) : (
          <CodeBox botUsername={status.botUsername} />
        )}
      </section>

      {link.linked ? (
        <section className="card">
          <h2>Pengaturan</h2>
          <SettingsForm link={link} />
        </section>
      ) : null}

      <section className="card">
        <h2>Catatan keamanan</h2>
        <ul>
          <li>
            Bot hanya bisa melakukan apa yang boleh Anda lakukan, dan hanya setelah Anda menekan
            tombol Simpan di Telegram.
          </li>
          <li>
            AI Gemini hanya menerima pesan atau foto struk yang Anda kirim. Data pembukuan (saldo,
            kategori, rekening) tidak pernah dikirim ke AI.
          </li>
          <li>
            Pada paket gratis Google, isi pesan dan foto yang dikirim ke AI dapat dipakai Google
            untuk meningkatkan produk. Jangan kirim foto yang berisi data sensitif lain.
          </li>
          <li>
            Kehilangan HP? Putuskan Telegram di sini atau lewat Keamanan; bot langsung berhenti.
          </li>
        </ul>
      </section>
    </div>
  );
}
