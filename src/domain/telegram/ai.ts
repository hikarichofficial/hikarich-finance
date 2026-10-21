/**
 * What the AI helper hands back (a reading of the owner's own message or receipt photo) and how it becomes the same
 * `ParsedExpense` the rule-based reader produces. The AI never receives books data, so everything it returns is
 * treated as untrusted text: checked here, then matched to categories and accounts by our own code. Decision 422.
 */
import { isIsoDate } from "./dates";
import type { EntityWord, ParsedExpense, ParsedLine } from "./message";

export interface AiExtraction {
  kind: "expense" | "report" | "other";
  merchant: string | null;
  date: string | null;
  items: Array<{ description: string; amount: number }>;
  total: number | null;
  paymentMethod: string | null;
  entity: EntityWord | null;
  periodText: string | null;
}

const MAX_AMOUNT = 100_000_000_000;
const MAX_ITEMS = 30;

function cleanText(value: string | null | undefined, max: number): string | null {
  if (!value) return null;
  const v = value
    .replace(/<[^>]*>/g, "")
    .replace(/[\u0000-\u001f<>]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return v.length === 0 ? null : v.slice(0, max);
}

function validAmount(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 && value <= MAX_AMOUNT;
}

/** A parsed expense from the AI's reading, or null when it holds no usable amount. */
export function aiToParsed(ai: AiExtraction, today: string): ParsedExpense | null {
  if (ai.kind !== "expense") return null;
  const merchant = cleanText(ai.merchant, 60);
  const items: ParsedLine[] = [];
  for (const item of ai.items.slice(0, MAX_ITEMS)) {
    if (!validAmount(item.amount)) continue;
    const description =
      cleanText(item.description, 200) ?? (merchant ? `Pembelian di ${merchant}` : "Pengeluaran");
    items.push({ description, amount: Math.round(item.amount), quantity: 1 });
  }
  const total = validAmount(ai.total) ? Math.round(ai.total) : null;
  const sum = items.reduce((s, l) => s + l.amount, 0);

  let lines = items;
  if (items.length === 0) {
    if (total === null) return null;
    lines = [
      {
        description: merchant ? `Pembelian di ${merchant}` : "Pengeluaran",
        amount: total,
        quantity: 1,
      },
    ];
  } else if (total !== null && total !== sum) {
    if (total > sum) {
      // Tax, service charge or rounding that the item list leaves out: keep it visible instead of hiding it.
      lines = [
        ...items,
        { description: "Pajak / biaya layanan / pembulatan", amount: total - sum, quantity: 1 },
      ];
    } else {
      lines = [
        {
          description: merchant ? `Pembelian di ${merchant}` : "Pengeluaran",
          amount: total,
          quantity: 1,
        },
      ];
    }
  }

  let date: string | null = null;
  if (
    ai.date &&
    isIsoDate(ai.date) &&
    ai.date <= today &&
    ai.date >= `${Number(today.slice(0, 4)) - 2}-01-01`
  ) {
    date = ai.date;
  }
  const accountWords =
    cleanText(ai.paymentMethod, 40)
      ?.toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length >= 2) ?? [];
  return {
    lines,
    total: lines.reduce((s, l) => s + l.amount, 0),
    date,
    payee: merchant,
    entityWord: ai.entity === "company" || ai.entity === "personal" ? ai.entity : null,
    accountWords,
  };
}
