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
import { formatDateEn, L, weekdayNameEn, type Lang } from "./i18n";
import { formatRupiah } from "./rupiah";

const MONTH_NAMES_EN = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
] as const;

function fdate(lang: Lang | undefined, iso: string, withYear = true): string {
  if (lang !== "en") return formatDateId(iso, withYear);
  const full = formatDateEn(iso);
  return withYear ? full : full.replace(/ \d{4}$/, "");
}

function fmonth(lang: Lang | undefined, iso: string): string {
  if (lang !== "en") return formatMonthId(iso);
  const [y, m] = iso.split("-").map(Number) as [number, number];
  return `${MONTH_NAMES_EN[m - 1] ?? ""} ${y}`;
}

function wday(lang: Lang | undefined, iso: string): string {
  return lang === "en" ? weekdayNameEn(iso) : weekdayName(iso);
}

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
  lang?: Lang,
): Period {
  const length = daysBetween(from, to) + 1;
  const prevTo = prev?.to ?? addDays(from, -1);
  const prevFrom = prev?.from ?? addDays(from, -length);
  return { from, to, label, prevFrom, prevTo, prevLabel: prev?.label ?? L(lang, "periode sebelumnya", "the previous period") };
}

/** The period the scheduled report of `kind` covers, given the Entity's today. */
export function periodForReport(kind: ReportKind, today: string, lang?: Lang): Period {
  if (kind === "daily") {
    return span(
      today,
      today,
      `${wday(lang, today)}, ${fdate(lang, today)}`,
      { from: addDays(today, -1), to: addDays(today, -1), label: L(lang, "kemarin", "yesterday") },
      lang,
    );
  }
  if (kind === "weekly") {
    const thisMonday = startOfWeek(today);
    const from = addDays(thisMonday, -7);
    const to = addDays(thisMonday, -1);
    return span(
      from,
      to,
      `${fdate(lang, from, false)} – ${fdate(lang, to)}`,
      {
        from: addDays(from, -7),
        to: addDays(from, -1),
        label: L(lang, "minggu sebelumnya", "the week before"),
      },
      lang,
    );
  }
  const prevMonthStart = addMonths(startOfMonth(today), -1);
  const prevPrevStart = addMonths(prevMonthStart, -1);
  return span(
    prevMonthStart,
    endOfMonth(prevMonthStart),
    fmonth(lang, prevMonthStart),
    { from: prevPrevStart, to: endOfMonth(prevPrevStart), label: fmonth(lang, prevPrevStart) },
    lang,
  );
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
  ["january", 1],
  ["february", 2],
  ["march", 3],
  ["may", 5],
  ["june", 6],
  ["july", 7],
  ["august", 8],
  ["aug", 8],
  ["october", 10],
  ["oct", 10],
  ["december", 12],
  ["dec", 12],
];

/** The period a question names (Indonesian or English); "this month" when it names none. Never reaches into the future. */
export function parsePeriod(text: string, today: string, lang?: Lang): Period {
  const t = ` ${normalizeText(text)} `;
  const has = (re: RegExp) => re.test(t);
  const yesterday = L(lang, "kemarin", "yesterday");

  if (has(/ (?:kemarin lusa|day before yesterday) /)) {
    const d = addDays(today, -2);
    return span(d, d, `${wday(lang, d)}, ${fdate(lang, d)}`, undefined, lang);
  }
  if (has(/ (?:kemarin|semalam|yesterday) /)) {
    const d = addDays(today, -1);
    return span(d, d, `${yesterday} (${fdate(lang, d)})`, undefined, lang);
  }
  if (has(/ (?:hari ini|today|barusan|tadi) /)) {
    return span(
      today,
      today,
      `${L(lang, "hari ini", "today")} (${fdate(lang, today)})`,
      { from: addDays(today, -1), to: addDays(today, -1), label: yesterday },
      lang,
    );
  }
  const lastN =
    /\b(\d{1,3}) hari (?:terakhir|belakangan|lalu)\b/.exec(t.trim()) ??
    /\b(?:last|past) (\d{1,3}) days\b/.exec(t.trim());
  if (lastN?.[1]) {
    const n = Math.max(1, Math.min(Number(lastN[1]), 366));
    return span(
      addDays(today, -(n - 1)),
      today,
      L(lang, `${n} hari terakhir`, `the last ${n} days`),
      undefined,
      lang,
    );
  }
  if (has(/ (?:minggu (?:lalu|kemarin|kemaren)|last week) /)) {
    const thisMonday = startOfWeek(today);
    const from = addDays(thisMonday, -7);
    const to = addDays(thisMonday, -1);
    return span(
      from,
      to,
      `${L(lang, "minggu lalu", "last week")} (${fdate(lang, from, false)} – ${fdate(lang, to)})`,
      {
        from: addDays(from, -7),
        to: addDays(from, -1),
        label: L(lang, "minggu sebelumnya", "the week before"),
      },
      lang,
    );
  }
  if (has(/ (?:minggu ini|pekan ini|seminggu|this week) /)) {
    const from = startOfWeek(today);
    const elapsed = daysBetween(from, today) + 1;
    return span(
      from,
      today,
      `${L(lang, "minggu ini", "this week")} (${fdate(lang, from, false)} – ${fdate(lang, today)})`,
      {
        from: addDays(from, -7),
        to: addDays(from, -8 + elapsed),
        label: L(lang, "minggu lalu pada hari yang sama", "the same days last week"),
      },
      lang,
    );
  }
  if (has(/ (?:bulan (?:lalu|kemarin|kemaren)|last month) /)) {
    const from = addMonths(startOfMonth(today), -1);
    return span(
      from,
      endOfMonth(from),
      fmonth(lang, from),
      {
        from: addMonths(from, -1),
        to: endOfMonth(addMonths(from, -1)),
        label: fmonth(lang, addMonths(from, -1)),
      },
      lang,
    );
  }
  if (has(/ (?:tahun ini|setahun|this year) /)) {
    const from = `${today.slice(0, 4)}-01-01`;
    return span(
      from,
      today,
      L(lang, `tahun ${today.slice(0, 4)} sampai hari ini`, `${today.slice(0, 4)} so far`),
      undefined,
      lang,
    );
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
    return span(
      from,
      to,
      fmonth(lang, from),
      {
        from: addMonths(from, -1),
        to: endOfMonth(addMonths(from, -1)),
        label: fmonth(lang, addMonths(from, -1)),
      },
      lang,
    );
  }
  const from = startOfMonth(today);
  const prevFrom = addMonths(from, -1);
  return span(
    from,
    today,
    L(lang, `${fmonth(lang, from)} sampai hari ini`, `${fmonth(lang, from)} so far`),
    { from: prevFrom, to: endOfMonth(prevFrom), label: fmonth(lang, prevFrom) },
    lang,
  );
}

export function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function percent(part: number, whole: number): string {
  if (whole <= 0) return "0%";
  return `${Math.round((part / whole) * 100)}%`;
}

function comparison(
  total: number,
  prevTotal: number | null,
  prevLabel: string,
  lang: Lang | undefined,
): string | null {
  if (prevTotal === null) return null;
  if (prevTotal === 0 && total === 0)
    return L(
      lang,
      `Sama dengan ${prevLabel}: tidak ada pengeluaran.`,
      `Same as ${prevLabel}: no expenses.`,
    );
  if (prevTotal === 0)
    return L(lang, `Pada ${prevLabel} tidak ada pengeluaran.`, `There were no expenses in ${prevLabel}.`);
  const diff = total - prevTotal;
  if (diff === 0)
    return L(
      lang,
      `Sama dengan ${prevLabel} (${formatRupiah(prevTotal)}).`,
      `Same as ${prevLabel} (${formatRupiah(prevTotal)}).`,
    );
  const icon = diff > 0 ? "📈" : "📉";
  const amount = formatRupiah(Math.abs(diff));
  const pct = percent(Math.abs(diff), prevTotal);
  return L(
    lang,
    `${icon} ${diff > 0 ? "naik" : "turun"} ${amount} (${pct}) dibanding ${prevLabel} (${formatRupiah(prevTotal)}).`,
    `${icon} ${diff > 0 ? "up" : "down"} ${amount} (${pct}) vs ${prevLabel} (${formatRupiah(prevTotal)}).`,
  );
}

function titleOf(kind: ReportKind | "ask", lang: Lang | undefined): string {
  switch (kind) {
    case "daily":
      return L(lang, "Laporan harian", "Daily report");
    case "weekly":
      return L(lang, "Laporan mingguan", "Weekly report");
    case "monthly":
      return L(lang, "Laporan bulanan", "Monthly report");
    case "ask":
      return L(lang, "Ringkasan", "Summary");
  }
}

export const TELEGRAM_LIMIT = 4096;

export function entityIcon(entityType: string): string {
  return entityType === "personal" ? "👤" : "🏢";
}

export function entityShort(entityType: string, lang?: Lang): string {
  return entityType === "personal" ? L(lang, "Pribadi", "Personal") : "PT";
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
  lang?: Lang,
): string {
  const lines: string[] = [];
  lines.push(`📊 <b>${titleOf(kind, lang)} — ${escapeHtml(period.label)}</b>`);
  lines.push(
    `${entityIcon(data.entityType)} ${escapeHtml(entityShort(data.entityType, lang))} · ${escapeHtml(data.entityName)}`,
  );
  lines.push("");
  if (data.count === 0) {
    lines.push(
      L(
        lang,
        "Tidak ada pengeluaran terkonfirmasi pada periode ini.",
        "No confirmed expenses in this period.",
      ),
    );
  } else {
    lines.push(
      L(
        lang,
        `Total pengeluaran: <b>${formatRupiah(data.total)}</b> (${data.count} catatan)`,
        `Total expenses: <b>${formatRupiah(data.total)}</b> (${data.count} entries)`,
      ),
    );
    const cmp = comparison(data.total, prevTotal, period.prevLabel, lang);
    if (cmp) lines.push(escapeHtml(cmp));
    const days = Math.max(1, daysBetween(period.from, period.to) + 1);
    if (days > 1)
      lines.push(
        `${L(lang, "Rata-rata per hari", "Average per day")}: ${formatRupiah(Math.round(data.total / days))}`,
      );

    lines.push("");
    lines.push(`<b>${L(lang, "Per kategori", "By category")}</b>`);
    for (const c of data.byCategory.slice(0, 8)) {
      lines.push(
        `• ${escapeHtml(c.name)} — ${formatRupiah(c.total)} (${percent(c.total, data.total)})`,
      );
    }
    if (data.byCategory.length > 8) {
      const rest = data.byCategory.slice(8).reduce((s, c) => s + c.total, 0);
      lines.push(
        `• ${L(lang, `Lainnya (${data.byCategory.length - 8} kategori)`, `Other (${data.byCategory.length - 8} categories)`)} — ${formatRupiah(rest)}`,
      );
    }

    if (kind === "daily" || (kind === "ask" && days === 1)) {
      lines.push("");
      lines.push(`<b>${L(lang, "Catatan hari ini", "Entries today")}</b>`);
      for (const e of data.entries.slice(0, 15)) {
        lines.push(
          `• ${escapeHtml(e.description)} — ${formatRupiah(e.amount)} (${escapeHtml(e.account)})`,
        );
      }
      if (data.count > 15)
        lines.push(L(lang, `… dan ${data.count - 15} lainnya`, `… and ${data.count - 15} more`));
    } else if (data.top.length > 0) {
      lines.push("");
      lines.push(`<b>${L(lang, "Terbesar", "Largest")}</b>`);
      for (const t of data.top.slice(0, 5)) {
        const who = t.payee ? ` · ${escapeHtml(t.payee)}` : "";
        lines.push(
          `• ${escapeHtml(fdate(lang, t.date, false))} ${escapeHtml(t.description)} — ${formatRupiah(t.amount)}${who}`,
        );
      }
    }
  }
  const notes: string[] = [];
  if (data.drafts > 0)
    notes.push(
      L(
        lang,
        `📝 ${data.drafts} draf belum dikonfirmasi (tidak dihitung di atas).`,
        `📝 ${data.drafts} draft(s) not confirmed yet (not counted above).`,
      ),
    );
  if (data.assetsToRegister > 0)
    notes.push(
      L(
        lang,
        `🧾 ${data.assetsToRegister} pembelian menunggu didaftarkan sebagai aset di website.`,
        `🧾 ${data.assetsToRegister} purchase(s) waiting to be registered as assets on the website.`,
      ),
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
  return `${cut.slice(0, lastNewline > 0 ? lastNewline : cut.length)}\n… (dipotong / cut)`;
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
