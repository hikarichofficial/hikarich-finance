/**
 * Dates as people say them in a chat ("kemarin", "tgl 20", "20 okt", "3 hari lalu") and calendar arithmetic on
 * plain `YYYY-MM-DD` strings. The caller supplies "today" (the Entity's own today), so nothing here reads a clock
 * or a time zone. Decision 422.
 */

export interface DateHint {
  date: string;
  start: number;
  end: number;
  raw: string;
}

const MONTHS: ReadonlyArray<readonly [RegExp, number]> = [
  [/^jan/, 1],
  [/^feb/, 2],
  [/^mar/, 3],
  [/^apr/, 4],
  [/^mei/, 5],
  [/^jun/, 6],
  [/^jul/, 7],
  [/^agu/, 8],
  [/^sep/, 9],
  [/^okt/, 10],
  [/^nov/, 11],
  [/^des/, 12],
];

export const MONTH_NAMES_ID = [
  "Januari",
  "Februari",
  "Maret",
  "April",
  "Mei",
  "Juni",
  "Juli",
  "Agustus",
  "September",
  "Oktober",
  "November",
  "Desember",
] as const;

const WEEKDAYS: Readonly<Record<string, number>> = {
  senin: 1,
  selasa: 2,
  rabu: 3,
  kamis: 4,
  jumat: 5,
  jum_at: 5,
  sabtu: 6,
  minggu: 0,
  ahad: 0,
};

const NUMBER_WORDS: Readonly<Record<string, number>> = {
  satu: 1,
  dua: 2,
  tiga: 3,
  empat: 4,
  lima: 5,
  enam: 6,
  tujuh: 7,
};

export function isIsoDate(value: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const probe = new Date(Date.UTC(y, mo - 1, d));
  return probe.getUTCFullYear() === y && probe.getUTCMonth() === mo - 1 && probe.getUTCDate() === d;
}

function toUtc(iso: string): Date {
  const [y, m, d] = iso.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d, 12));
}

function fromUtc(date: Date): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  const d = String(date.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function addDays(iso: string, days: number): string {
  const date = toUtc(iso);
  date.setUTCDate(date.getUTCDate() + days);
  return fromUtc(date);
}

/** Monday = 1 ... Sunday = 7 (ISO), the way weeks are counted in Indonesia. */
export function isoWeekday(iso: string): number {
  const day = toUtc(iso).getUTCDay();
  return day === 0 ? 7 : day;
}

export function startOfWeek(iso: string): string {
  return addDays(iso, 1 - isoWeekday(iso));
}

export function startOfMonth(iso: string): string {
  return `${iso.slice(0, 7)}-01`;
}

export function endOfMonth(iso: string): string {
  const [y, m] = iso.split("-").map(Number) as [number, number];
  return fromUtc(new Date(Date.UTC(y, m, 0, 12)));
}

export function addMonths(iso: string, months: number): string {
  const [y, m] = iso.split("-").map(Number) as [number, number];
  const target = new Date(Date.UTC(y, m - 1 + months, 1, 12));
  return fromUtc(target);
}

/** 5 Okt 2026. */
export function formatDateId(iso: string, withYear = true): string {
  const [y, m, d] = iso.split("-").map(Number) as [number, number, number];
  const month = (MONTH_NAMES_ID[m - 1] ?? "").slice(0, 3);
  return withYear ? `${d} ${month} ${y}` : `${d} ${month}`;
}

export function formatMonthId(iso: string): string {
  const [y, m] = iso.split("-").map(Number) as [number, number];
  return `${MONTH_NAMES_ID[m - 1] ?? ""} ${y}`;
}

function make(y: number, m: number, d: number): string | null {
  const iso = `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
  return isCalendarDate(y, m, d) ? iso : null;
}

function isCalendarDate(y: number, m: number, d: number): boolean {
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  const probe = new Date(Date.UTC(y, m - 1, d));
  return probe.getUTCMonth() === m - 1 && probe.getUTCDate() === d;
}

function monthFromWord(word: string): number | null {
  const w = word.toLowerCase();
  for (const [re, n] of MONTHS) if (re.test(w)) return n;
  return null;
}

/** A day of the current month; a day still ahead of today means the previous month's. */
function dayOfRecentMonth(day: number, today: string): string | null {
  const [y, m] = today.split("-").map(Number) as [number, number];
  const here = make(y, m, day);
  if (here && here <= today) return here;
  const prev = addMonths(today, -1);
  const [py, pm] = prev.split("-").map(Number) as [number, number];
  return make(py, pm, day);
}

/**
 * The first date expression in `text`, resolved against `today`. Future dates are not guessed: an expense is
 * something that already happened ("20 okt" later than today means last year, "tgl 28" means last month).
 */
export function parseDateHint(text: string, today: string): DateHint | null {
  const lower = text.toLowerCase();
  const candidates: DateHint[] = [];
  const push = (m: RegExpExecArray | null, date: string | null) => {
    if (m && date && date <= today) {
      candidates.push({ date, start: m.index, end: m.index + m[0].length, raw: m[0] });
    }
  };

  push(/\bkemarin\s+lusa\b/.exec(lower), addDays(today, -2));
  push(/\b(?:kemarin|semalam|kemaren)\b(?!\s+lusa)/.exec(lower), addDays(today, -1));
  push(
    /\b(?:hari\s+ini|barusan|baru\s+saja|tadi(?:\s+(?:pagi|siang|sore|malam))?|sore\s+tadi)\b/.exec(
      lower,
    ),
    today,
  );

  const ago = /\b(\d{1,2}|satu|dua|tiga|empat|lima|enam|tujuh)\s+hari\s+(?:yang\s+)?lalu\b/.exec(
    lower,
  );
  if (ago?.[1]) {
    const n = NUMBER_WORDS[ago[1]] ?? Number(ago[1]);
    if (n >= 1 && n <= 60) push(ago, addDays(today, -n));
  }

  const dayMonth = new RegExp(
    String.raw`\b(\d{1,2})\s*(jan(?:uari)?|feb(?:ruari)?|mar(?:et)?|apr(?:il)?|mei|jun(?:i)?|jul(?:i)?|agu(?:stus)?|sep(?:t(?:ember)?)?|okt(?:ober)?|nov(?:ember)?|des(?:ember)?)\b(?:\s*(\d{4}))?`,
  ).exec(lower);
  if (dayMonth?.[1] && dayMonth[2]) {
    const day = Number(dayMonth[1]);
    const month = monthFromWord(dayMonth[2]);
    const [ty] = today.split("-").map(Number) as [number];
    if (month) {
      const year = dayMonth[3] ? Number(dayMonth[3]) : ty;
      let date = make(year, month, day);
      if (date && date > today && !dayMonth[3]) date = make(year - 1, month, day);
      push(dayMonth, date);
    }
  }

  const slash = /\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b/.exec(lower);
  if (slash?.[1] && slash[2]) {
    const [ty] = today.split("-").map(Number) as [number];
    let year = ty;
    if (slash[3]) year = slash[3].length === 2 ? 2000 + Number(slash[3]) : Number(slash[3]);
    let date = make(year, Number(slash[2]), Number(slash[1]));
    if (date && date > today && !slash[3])
      date = make(year - 1, Number(slash[2]), Number(slash[1]));
    push(slash, date);
  }

  const dom =
    /\b(?:tgl|tanggal)\.?\s*(\d{1,2})\b(?!\s*(?:jan|feb|mar|apr|mei|jun|jul|agu|sep|okt|nov|des))/.exec(
      lower,
    );
  if (dom?.[1]) push(dom, dayOfRecentMonth(Number(dom[1]), today));

  const weekday =
    /\b(senin|selasa|rabu|kamis|jumat|jum'at|sabtu|minggu|ahad)\s+(?:lalu|kemarin)\b/.exec(lower);
  if (weekday?.[1]) {
    const target = WEEKDAYS[weekday[1].replace("'", "_")];
    if (target !== undefined) {
      const current = isoWeekday(today) % 7; // Sunday = 0
      let back = (current - target + 7) % 7;
      if (back === 0) back = 7;
      push(weekday, addDays(today, -back));
    }
  }

  if (candidates.length === 0) return null;
  candidates.sort((a, b) => a.start - b.start);
  return candidates[0] ?? null;
}
