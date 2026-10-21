/**
 * The bot speaks Indonesian (the default) or English, chosen per paired owner with /bahasa or /language. Only what the
 * bot SAYS is translated: category names, vendors and the books stay as the owner wrote them. Both texts sit next to
 * each other at the call site, so a change to one is seen against the other.
 */
export type Lang = "id" | "en";

export function parseLang(value: unknown): Lang {
  return value === "en" ? "en" : "id";
}

/** The Indonesian text, or the English one when the owner chose English. */
export function L(lang: Lang | undefined, id: string, en: string): string {
  return lang === "en" ? en : id;
}

const MONTHS_EN = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
] as const;
const WEEKDAYS_EN = [
  "Sunday",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
] as const;

/** "21 Oct 2026" for an ISO date (YYYY-MM-DD); the Indonesian form comes from `formatDateId`. */
export function formatDateEn(iso: string): string {
  const [y, m, d] = iso.split("-");
  const month = MONTHS_EN[Number(m) - 1];
  return month && y && d ? `${Number(d)} ${month} ${y}` : iso;
}

export function weekdayNameEn(iso: string): string {
  const day = new Date(`${iso}T00:00:00Z`).getUTCDay();
  return WEEKDAYS_EN[day] ?? "";
}
