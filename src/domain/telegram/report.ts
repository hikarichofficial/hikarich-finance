/**
 * Periods people ask for ("minggu lalu", "7 hari terakhir") and the text of the daily, weekly and monthly
 * summaries. Pure: the caller fetches the numbers (`telegram_summary`) and sends the text. Decision 422.
 */
import { normalizeText } from "./categorize";
import {
  addDays,
  addMonths,
  endOfMonth,
  formatDateId,
  formatMonthId,
  isoWeekday,
  startOfMonth,
  startOfWeek,
} from "./dates";
import { formatRupiah } from "./rupiah";

export type ReportKind = "daily" | "weekly" | "monthly";

export interface Period {
  from: string;
  to: string;
  label: string;
  /** The stretch right before, for "naik / turun" comparisons. */
  prevFrom: string;
  prevTo: string;
  prevLabel: string;
}

export interface SummaryData {
  entityName: string;
  entityType: string;
  from: string;
  to: string;
  total: number;
  count: number;
  byCategory: Array<{ name: string; total: number; count: number }>;
  top: Array<{ date: string; description: string; amount: number; payee: string | null }>;
  entries: Array<{ date: string; description: string; amount: number; account: string }>;
  drafts: number;
  assetsToRegister: number;
}

const WEEKDAY_NAMES = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"] as const;

export function weekdayName(iso: string): string {
  return WEEKDAY_NAMES[isoWeekday(iso) - 1] ?? "";
}

function daysBetween(from: string, to: string): number {
  const a = Date.parse(`${from}T12:00:00Z`);
  const b = Date.parse(`${to}T12:00:00Z`);
  return Math.round((b - a) / 86_400_000);
}

function span(
  from: string,
  to: string,
  label: string,
  prev?: { from: string; to: string; label: string },
): Period {
  const length = daysBetween(from, to) + 1;
  const prevTo = prev?.to ?? addDays(from, -1);
  const prevFrom = prev?.from ?? addDays(from, -length);
  return { from, to, label, prevFrom, prevTo, prevLabel: prev?.label ?? "periode sebelumnya" };
}

/** The period the scheduled report of `kind` covers, given the Entity's today. */
export function periodForReport(kind: ReportKind, today: string): Period {
  if (kind === "daily") {
    return span(today, today, `${weekdayName(today)}, ${formatDateId(today)}`, {
      from: addDays(today, -1),
      to: addDays(today, -1),
      label: "kemarin",
    });
  }
  if (kind === "weekly") {
    const thisMonday = startOfWeek(today);
    const from = addDays(thisMonday, -7);
    const to = addDays(thisMonday, -1);
    return span(from, to, `${formatDateId(from, false)} – ${formatDateId(to)}`, {
      from: addDays(from, -7),
      to: addDays(from, -1),
      label: "minggu sebelumnya",
    });
  }
  const prevMonthStart = addMonths(startOfMonth(today), -1);
  const prevPrevStart = addMonths(prevMonthStart, -1);
  return span(prevMonthStart, endOfMonth(prevMonthStart), formatMonthId(prevMonthStart), {
    from: prevPrevStart,
    to: endOfMonth(prevPrevStart),
    label: formatMonthId(prevPrevStart),
  });
}

const MONTH_LOOKUP: ReadonlyArray<readonly [string, number]> = [
  ["januari", 1],
  ["jan", 1],
  ["februari", 2],
  ["feb", 2],
  ["maret", 3],
  ["mar", 3],
  ["april", 4],
  ["apr", 4],
  ["mei", 5],
  ["juni", 6],
  ["jun", 6],
  ["juli", 7],
  ["jul", 7],
  ["agustus", 8],
  ["agu", 8],
  ["agt", 8],
  ["september", 9],
  ["sep", 9],
  ["sept", 9],
  ["oktober", 10],
  ["okt", 10],
  ["november", 11],
  ["nov", 11],
  ["desember", 12],
  ["des", 12],
];

/** The period a question names; "bulan ini" when it names none. Never reaches into the future. */
export function parsePeriod(text: string, today: string): Period {
  const t = ` ${normalizeText(text)} `;
  const has = (re: RegExp) => re.test(t);

  if (has(/ kemarin lusa /)) {
    const d = addDays(today, -2);
    return span(d, d, `${weekdayName(d)}, ${formatDateId(d)}`);
  }
  if (has(/ (?:kemarin|semalam) /)) {
    const d = addDays(today, -1);
    return span(d, d, `kemarin (${formatDateId(d)})`);
  }
  if (has(/ (?:hari ini|today|barusan|tadi) /)) {
    return span(today, today, `hari ini (${formatDateId(today)})`, {
      from: addDays(today, -1),
      to: addDays(today, -1),
      label: "kemarin",
    });
  }
  const lastN = /\b(\d{1,3}) hari (?:terakhir|belakangan|lalu)\b/.exec(t.trim());
  if (lastN?.[1]) {
    const n = Math.max(1, Math.min(Number(lastN[1]), 366));
    return span(addDays(today, -(n - 1)), today, `${n} hari terakhir`);
  }
  if (has(/ minggu (?:lalu|kemarin|kemaren) /)) {
    const thisMonday = startOfWeek(today);
    const from = addDays(thisMonday, -7);
    const to = addDays(thisMonday, -1);
    return span(from, to, `minggu lalu (${formatDateId(from, false)} – ${formatDateId(to)})`, {
      from: addDays(from, -7),
      to: addDays(from, -1),
      label: "minggu sebelumnya",
    });
  }
  if (has(/ (?:minggu ini|pekan ini|seminggu) /)) {
    const from = startOfWeek(today);
    const elapsed = daysBetween(from, today) + 1;
    return span(from, today, `minggu ini (${formatDateId(from, false)} – ${formatDateId(today)})`, {
      from: addDays(from, -7),
      to: addDays(from, -8 + elapsed),
      label: "minggu lalu pada hari yang sama",
    });
  }
  if (has(/ bulan (?:lalu|kemarin|kemaren) /)) {
    const from = addMonths(startOfMonth(today), -1);
    return span(from, endOfMonth(from), formatMonthId(from), {
      from: addMonths(from, -1),
      to: endOfMonth(addMonths(from, -1)),
      label: formatMonthId(addMonths(from, -1)),
    });
  }
  if (has(/ (?:tahun ini|setahun) /)) {
    const from = `${today.slice(0, 4)}-01-01`;
    return span(from, today, `tahun ${today.slice(0, 4)} sampai hari ini`);
  }
  for (const [word, month] of MONTH_LOOKUP) {
    const m = new RegExp(`\\b${word}(?: (\\d{4}))?\\b`).exec(t);
    if (!m) continue;
    // "mar" inside other words is excluded by \b; "mei", "des" stand alone only.
    const year = m[1] ? Number(m[1]) : Number(today.slice(0, 4));
    let from = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-01`;
    if (from > today)
      from = `${String(year - 1).padStart(4, "0")}-${String(month).padStart(2, "0")}-01`;
    const to = endOfMonth(from) > today ? today : endOfMonth(from);
    return span(from, to, formatMonthId(from), {
      from: addMonths(from, -1),
      to: endOfMonth(addMonths(from, -1)),
      label: formatMonthId(addMonths(from, -1)),
    });
  }
  const from = startOfMonth(today);
  const prevFrom = addMonths(from, -1);
  return span(from, today, `${formatMonthId(from)} sampai hari ini`, {
    from: prevFrom,
    to: endOfMonth(prevFrom),
    label: formatMonthId(prevFrom),
  });
}

export function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function percent(part: number, whole: number): string {
  if (whole <= 0) return "0%";
  return `${Math.round((part / whole) * 100)}%`;
}

function comparison(total: number, prevTotal: number | null, prevLabel: string): string | null {
  if (prevTotal === null) return null;
  if (prevTotal === 0 && total === 0) return `Sama dengan ${prevLabel}: tidak ada pengeluaran.`;
  if (prevTotal === 0) return `Pada ${prevLabel} tidak ada pengeluaran.`;
  const diff = total - prevTotal;
  if (diff === 0) return `Sama dengan ${prevLabel} (${formatRupiah(prevTotal)}).`;
  const direction = diff > 0 ? "naik" : "turun";
  const icon = diff > 0 ? "📈" : "📉";
  return `${icon} ${direction} ${formatRupiah(Math.abs(diff))} (${percent(Math.abs(diff), prevTotal)}) dibanding ${prevLabel} (${formatRupiah(prevTotal)}).`;
}

const TITLES: Record<ReportKind | "ask", string> = {
  daily: "Laporan harian",
  weekly: "Laporan mingguan",
  monthly: "Laporan bulanan",
  ask: "Ringkasan",
};

export const TELEGRAM_LIMIT = 4096;

export function entityIcon(entityType: string): string {
  return entityType === "personal" ? "👤" : "🏢";
}

export function entityShort(entityType: string): string {
  return entityType === "personal" ? "Pribadi" : "PT";
}

/**
 * The text of one summary. `kind` picks the title; `prev` is the total of the stretch before (null to leave the
 * comparison out). Daily reports list the day's entries; weekly and monthly ones list the biggest items.
 */
export function formatSummary(
  kind: ReportKind | "ask",
  period: Period,
  data: SummaryData,
  prevTotal: number | null,
): string {
  const lines: string[] = [];
  lines.push(`📊 <b>${TITLES[kind]} — ${escapeHtml(period.label)}</b>`);
  lines.push(
    `${entityIcon(data.entityType)} ${escapeHtml(entityShort(data.entityType))} · ${escapeHtml(data.entityName)}`,
  );
  lines.push("");
  if (data.count === 0) {
    lines.push("Tidak ada pengeluaran terkonfirmasi pada periode ini.");
  } else {
    lines.push(`Total pengeluaran: <b>${formatRupiah(data.total)}</b> (${data.count} catatan)`);
    const cmp = comparison(data.total, prevTotal, period.prevLabel);
    if (cmp) lines.push(escapeHtml(cmp));
    const days = Math.max(1, daysBetween(period.from, period.to) + 1);
    if (days > 1) lines.push(`Rata-rata per hari: ${formatRupiah(Math.round(data.total / days))}`);

    lines.push("");
    lines.push("<b>Per kategori</b>");
    for (const c of data.byCategory.slice(0, 8)) {
      lines.push(
        `• ${escapeHtml(c.name)} — ${formatRupiah(c.total)} (${percent(c.total, data.total)})`,
      );
    }
    if (data.byCategory.length > 8) {
      const rest = data.byCategory.slice(8).reduce((s, c) => s + c.total, 0);
      lines.push(`• Lainnya (${data.byCategory.length - 8} kategori) — ${formatRupiah(rest)}`);
    }

    if (kind === "daily" || (kind === "ask" && days === 1)) {
      lines.push("");
      lines.push("<b>Catatan hari ini</b>");
      for (const e of data.entries.slice(0, 15)) {
        lines.push(
          `• ${escapeHtml(e.description)} — ${formatRupiah(e.amount)} (${escapeHtml(e.account)})`,
        );
      }
      if (data.count > 15) lines.push(`… dan ${data.count - 15} lainnya`);
    } else if (data.top.length > 0) {
      lines.push("");
      lines.push("<b>Terbesar</b>");
      for (const t of data.top.slice(0, 5)) {
        const who = t.payee ? ` · ${escapeHtml(t.payee)}` : "";
        lines.push(
          `• ${escapeHtml(formatDateId(t.date, false))} ${escapeHtml(t.description)} — ${formatRupiah(t.amount)}${who}`,
        );
      }
    }
  }
  const notes: string[] = [];
  if (data.drafts > 0)
    notes.push(`📝 ${data.drafts} draf belum dikonfirmasi (tidak dihitung di atas).`);
  if (data.assetsToRegister > 0)
    notes.push(
      `🧾 ${data.assetsToRegister} pembelian menunggu didaftarkan sebagai aset di website.`,
    );
  if (notes.length > 0) {
    lines.push("");
    lines.push(...notes);
  }
  return fit(lines.join("\n"));
}

/** Keeps a message under Telegram's limit without cutting an HTML tag in half. */
export function fit(text: string): string {
  if (text.length <= TELEGRAM_LIMIT) return text;
  const cut = text.slice(0, TELEGRAM_LIMIT - 40);
  const lastNewline = cut.lastIndexOf("\n");
  return `${cut.slice(0, lastNewline > 0 ? lastNewline : cut.length)}\n… (dipotong)`;
}

/** A combined message for people with both an Entity of the company and a personal one. */
export function joinSummaries(parts: readonly string[]): string[] {
  const messages: string[] = [];
  let current = "";
  for (const part of parts) {
    const next = current ? `${current}\n\n──────────\n\n${part}` : part;
    if (next.length > TELEGRAM_LIMIT) {
      if (current) messages.push(current);
      current = part;
    } else {
      current = next;
    }
  }
  if (current) messages.push(current);
  return messages;
}
