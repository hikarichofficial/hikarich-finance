import { formatDateId } from "@/domain/telegram/dates";
import { formatDateEn, L, type Lang } from "@/domain/telegram/i18n";
import { escapeHtml } from "@/domain/telegram/report";
import { formatRupiah } from "@/domain/telegram/rupiah";
import type { TgCallbackQuery } from "./api";
import type { BotDeps } from "./bot";
import { errorLine } from "./errors";
import type { DraftAsset, Identity, OpenLoan } from "./store";

/**
 * Two follow-ups that need the owner's own decision and therefore never happen silently (decision 422):
 *  - a fixed asset: the website opens a draft asset when a purchase on an asset category is confirmed; the owner picks
 *    how long it is depreciated here and the bot activates it through the website's own function;
 *  - a loan instalment: the bot lists the debts with their next instalment, asks which one and from which account,
 *    shows the amounts the schedule dictates and pays only after the final button.
 * Callback data is stateless (`a|<months>|<asset>` and `l|<step>|<loan>[:<account>]`), so a stale button is simply refused
 * by the database.
 */

const ASSET_CHOICES: ReadonlyArray<{ months: number; years: number }> = [
  { months: 48, years: 4 },
  { months: 96, years: 8 },
  { months: 192, years: 16 },
  { months: 240, years: 20 },
];

function dateOf(lang: Lang, date: string): string {
  return lang === "en" ? formatDateEn(date) : formatDateId(date);
}

function threadOpts(thread: number) {
  return thread ? { threadId: thread } : {};
}

// ---- fixed assets -----------------------------------------------------------------------------------------------

/** After a confirmed entry: ask about each draft asset the website opened from it. Returns how many were offered. */
export async function offerAssets(
  expenseId: string,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<number> {
  const lang = who.lang;
  let assets: DraftAsset[];
  try {
    assets = await deps.store.expenseAssets(who.linkId, expenseId);
  } catch {
    return 0;
  }
  for (const asset of assets.slice(0, 5)) {
    if (!asset.canManage) {
      await deps.api.sendMessage(
        chat,
        L(
          lang,
          `🏷️ <b>${escapeHtml(asset.name)}</b> (${formatRupiah(asset.cost)}) adalah barang tahan lama. Akunmu belum boleh mengelola aset, jadi aktifkan di website (menu Aset).`,
          `🏷️ <b>${escapeHtml(asset.name)}</b> (${formatRupiah(asset.cost)}) is a durable item. Your account may not manage assets, so activate it on the website (Assets menu).`,
        ),
        threadOpts(thread),
      );
      continue;
    }
    if (asset.entityType === "personal") {
      await deps.api.sendMessage(
        chat,
        L(
          lang,
          `🏷️ <b>${escapeHtml(asset.name)}</b> — ${formatRupiah(asset.cost)}\nAset pribadi dicatat sebesar harga perolehan dan <b>tidak disusutkan</b>. Daftarkan sebagai aset?`,
          `🏷️ <b>${escapeHtml(asset.name)}</b> — ${formatRupiah(asset.cost)}\nA personal asset is recorded at cost and is <b>not depreciated</b>. Register it as an asset?`,
        ),
        {
          ...threadOpts(thread),
          keyboard: {
            rows: [
              [
                { text: L(lang, "✅ Daftarkan aset", "✅ Register asset"), data: `a|0|${asset.assetId}` },
                { text: L(lang, "Nanti di website", "Later on the website"), data: `a|no|${asset.assetId}` },
              ],
            ],
          },
        },
      );
      continue;
    }
    await deps.api.sendMessage(
      chat,
      L(
        lang,
        `🏷️ <b>${escapeHtml(asset.name)}</b> — ${formatRupiah(asset.cost)}\nBarang tahan lama ini disusutkan <b>garis lurus</b>. Berapa lama masa manfaatnya? (Kelompok pajak umum: 4, 8, 16 atau 20 tahun; kelas pajak dan penyesuaian lain bisa diatur di website.)`,
        `🏷️ <b>${escapeHtml(asset.name)}</b> — ${formatRupiah(asset.cost)}\nThis durable item is depreciated <b>straight-line</b>. How long is its useful life? (Common tax groups: 4, 8, 16 or 20 years; tax class and other adjustments can be set on the website.)`,
      ),
      {
        ...threadOpts(thread),
        keyboard: {
          rows: [
            ASSET_CHOICES.map((c) => ({
              text: L(lang, `${c.years} tahun`, `${c.years} years`),
              data: `a|${c.months}|${asset.assetId}`,
            })),
            [{ text: L(lang, "Nanti di website", "Later on the website"), data: `a|no|${asset.assetId}` }],
          ],
        },
      },
    );
  }
  return assets.length;
}

export async function handleAssetCallback(
  action: string,
  arg: string,
  cb: TgCallbackQuery,
  who: Identity,
  chat: number,
  messageId: number,
  deps: BotDeps,
): Promise<void> {
  const { api, store } = deps;
  const lang = who.lang;
  if (action === "no" || !/^[0-9a-f-]{36}$/.test(arg)) {
    await api.answerCallback(cb.id, L(lang, "Oke, nanti.", "Okay, later."));
    await api.editMessage(
      chat,
      messageId,
      L(
        lang,
        "Oke. Aset tetap ini tetap berstatus draf; aktifkan di website (menu Aset) kapan saja.",
        "Okay. This fixed asset stays a draft; activate it on the website (Assets menu) any time.",
      ),
    );
    return;
  }
  const months = Number(action);
  const allowed = months === 0 || ASSET_CHOICES.some((c) => c.months === months);
  if (!allowed) {
    await api.answerCallback(cb.id, L(lang, "Pilihan itu tidak berlaku.", "That choice is not valid."));
    return;
  }
  try {
    const lines = await store.activateAsset(who.linkId, `tg-act-${arg}`, arg, months || null);
    await api.answerCallback(cb.id, L(lang, "Aset aktif", "Asset active"));
    await api.editMessage(
      chat,
      messageId,
      months === 0
        ? L(
            lang,
            "✅ Aset terdaftar sebesar harga perolehan (tidak disusutkan).",
            "✅ Asset registered at cost (not depreciated).",
          )
        : L(
            lang,
            `✅ Aset aktif, disusutkan garis lurus ${months / 12} tahun (${lines} bulan). Penyusutan dijadwalkan di website.`,
            `✅ Asset active, depreciated straight-line over ${months / 12} years (${lines} months). Depreciation is scheduled on the website.`,
          ),
    );
  } catch (error) {
    await api.answerCallback(cb.id, L(lang, "Gagal", "Failed"));
    await api.editMessage(
      chat,
      messageId,
      `⚠️ ${L(lang, "Aset belum diaktifkan", "Asset not activated")}: ${escapeHtml(errorLine(error, lang))}`,
    );
  }
}

// ---- loan instalments -------------------------------------------------------------------------------------------

function loanLine(loan: OpenLoan, index: number, lang: Lang): string {
  const date = dateOf(lang, loan.dueDate);
  const due = loan.overdue
    ? L(lang, `⚠️ lewat jatuh tempo ${date}`, `⚠️ overdue since ${date}`)
    : L(lang, `jatuh tempo ${date}`, `due ${date}`);
  const nth = L(lang, `cicilan ke-${loan.seq}`, `instalment #${loan.seq}`);
  return `${index + 1}. <b>${escapeHtml(loan.counterparty)}</b> (${escapeHtml(loan.loanNumber)}) · ${escapeHtml(loan.entityName)}\n   ${nth}, ${due} — <b>${formatRupiah(loan.amount)}</b>`;
}

/** Entry: the owner talks about an instalment. Lists the debts, never records anything yet. */
export async function startLoanPayment(
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const lang = who.lang;
  let loans: OpenLoan[];
  try {
    loans = await deps.store.openLoans(who.linkId);
  } catch (error) {
    await deps.api.sendMessage(chat, `⚠️ ${escapeHtml(errorLine(error, lang))}`, threadOpts(thread));
    return;
  }
  if (loans.length === 0) {
    await deps.api.sendMessage(
      chat,
      L(
        lang,
        "Tidak ada pinjaman aktif dengan cicilan yang menunggu, atau akunmu belum boleh mengelola pinjaman. Pinjaman baru dibuat dan diaktifkan di website (menu Pinjaman).",
        "There is no active loan with an instalment waiting, or your account may not manage loans. New loans are created and activated on the website (Loans menu).",
      ),
      threadOpts(thread),
    );
    return;
  }
  const shown = loans.slice(0, 8);
  await deps.api.sendMessage(
    chat,
    `💳 <b>${L(lang, "Cicilan mana yang dibayar?", "Which instalment is being paid?")}</b>\n${L(lang, "Jumlahnya mengikuti jadwal pinjaman (pokok + bunga), bukan pengeluaran biasa.", "The amount follows the loan schedule (principal + interest); it is not an ordinary expense.")}\n\n${shown.map((l, i) => loanLine(l, i, lang)).join("\n")}`,
    {
      ...threadOpts(thread),
      keyboard: {
        rows: [
          ...shown.map((l, i) => [
            { text: `${i + 1}. ${l.counterparty}`.slice(0, 40), data: `l|p|${l.loanId}` },
          ]),
          [{ text: L(lang, "Batal", "Cancel"), data: "l|no|" }],
        ],
      },
    },
  );
}

export async function handleLoanCallback(
  action: string,
  arg: string,
  cb: TgCallbackQuery,
  who: Identity,
  chat: number,
  messageId: number,
  deps: BotDeps,
): Promise<void> {
  const { api, store } = deps;
  const lang = who.lang;
  if (action === "no") {
    await api.answerCallback(cb.id, L(lang, "Dibatalkan", "Cancelled"));
    await api.editMessage(
      chat,
      messageId,
      L(lang, "❌ Dibatalkan. Tidak ada cicilan yang dicatat.", "❌ Cancelled. No instalment was recorded."),
    );
    return;
  }
  const [loanId = "", accountKey = ""] = arg.split(":");
  if (!/^[0-9a-f-]{36}$/.test(loanId)) {
    await api.answerCallback(cb.id, L(lang, "Pilihan itu tidak berlaku.", "That choice is not valid."));
    return;
  }
  let loans: OpenLoan[];
  try {
    loans = await store.openLoans(who.linkId);
  } catch (error) {
    await api.answerCallback(cb.id, L(lang, "Gagal", "Failed"));
    await api.editMessage(chat, messageId, `⚠️ ${escapeHtml(errorLine(error, lang))}`);
    return;
  }
  const loan = loans.find((l) => l.loanId === loanId);
  if (!loan) {
    await api.answerCallback(cb.id, L(lang, "Cicilan itu sudah tidak menunggu.", "That instalment is no longer waiting."));
    await api.editMessage(
      chat,
      messageId,
      L(
        lang,
        "Pinjaman itu tidak punya cicilan yang menunggu lagi (mungkin sudah dibayar).",
        "That loan has no instalment waiting any more (it may already be paid).",
      ),
    );
    return;
  }

  if (action === "p") {
    if (loan.accounts.length === 0) {
      await api.answerCallback(cb.id);
      await api.editMessage(
        chat,
        messageId,
        L(
          lang,
          "Entitas ini belum punya rekening aktif untuk membayar. Tambahkan rekening di website dulu.",
          "This entity has no active account to pay from. Add an account on the website first.",
        ),
      );
      return;
    }
    await api.answerCallback(cb.id);
    await api.editMessage(chat, messageId, `💳 <b>${L(lang, "Dibayar dari rekening mana?", "Which account pays it?")}</b>\n\n${loanLine(loan, 0, lang).replace(/^1\. /, "")}`, {
      rows: [
        ...loan.accounts.slice(0, 8).map((a) => [
          { text: a.name.slice(0, 40), data: `l|a|${loanId}:${a.id.slice(0, 8)}` },
        ]),
        [{ text: L(lang, "Batal", "Cancel"), data: "l|no|" }],
      ],
    });
    return;
  }

  const account = loan.accounts.find((a) => a.id.startsWith(accountKey));
  if (!account) {
    await api.answerCallback(cb.id, L(lang, "Rekening itu tidak berlaku.", "That account is not valid."));
    return;
  }

  if (action === "a") {
    await api.answerCallback(cb.id);
    await api.editMessage(
      chat,
      messageId,
      [
        `📝 <b>${L(lang, "Cek dulu sebelum dibayar", "Check before paying")}</b>`,
        `${L(lang, "Pinjaman", "Loan")}: <b>${escapeHtml(loan.counterparty)}</b> (${escapeHtml(loan.loanNumber)}) · ${escapeHtml(loan.entityName)}`,
        L(
          lang,
          `Cicilan ke-${loan.seq}, jatuh tempo ${formatDateId(loan.dueDate)}`,
          `Instalment #${loan.seq}, due ${formatDateEn(loan.dueDate)}`,
        ),
        `${L(lang, "Dari rekening", "From account")}: ${escapeHtml(account.name)}`,
        `<b>${L(lang, "Jumlah", "Amount")}: ${formatRupiah(loan.amount)}</b> ${L(lang, "(pokok + bunga sesuai jadwal)", "(principal + interest per schedule)")}`,
        "",
        L(
          lang,
          "Tanggal pembayaran: hari ini. Pembayaran ini mengurangi saldo rekening dan utang pinjaman.",
          "Payment date: today. This reduces the account balance and the loan debt.",
        ),
      ].join("\n"),
      {
        rows: [
          [
            { text: L(lang, "✅ Bayar", "✅ Pay"), data: `l|go|${loanId}:${account.id.slice(0, 8)}` },
            { text: L(lang, "Batal", "Cancel"), data: "l|no|" },
          ],
        ],
      },
    );
    return;
  }

  if (action === "go") {
    try {
      await store.payLoan(who.linkId, `tg-loan-${loanId}-${loan.seq}`, loanId, account.id);
      await api.answerCallback(cb.id, L(lang, "Tercatat", "Recorded"));
      await api.editMessage(
        chat,
        messageId,
        L(
          lang,
          `✅ Cicilan ke-${loan.seq} <b>${escapeHtml(loan.counterparty)}</b> dibayar ${formatRupiah(loan.amount)} dari ${escapeHtml(account.name)}.`,
          `✅ Instalment #${loan.seq} of <b>${escapeHtml(loan.counterparty)}</b> paid: ${formatRupiah(loan.amount)} from ${escapeHtml(account.name)}.`,
        ),
      );
    } catch (error) {
      await api.answerCallback(cb.id, L(lang, "Gagal", "Failed"));
      await api.editMessage(
        chat,
        messageId,
        `⚠️ <b>${L(lang, "Belum dibayar", "Not paid")}:</b> ${escapeHtml(errorLine(error, lang))}`,
      );
    }
    return;
  }
  await api.answerCallback(cb.id);
}
