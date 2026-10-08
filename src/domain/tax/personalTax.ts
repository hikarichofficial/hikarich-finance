import { Decimal } from "@/domain/money/decimal";
import type { PersonalTariffParams, PersonalTaxSummary, PtkpStatus } from "@/schemas/personalTax";

/**
 * The yearly income-tax estimate of a Personal book (decision 365). Two calculations side by side, as the owner
 * asked:
 *   - PPh Final UMKM 0,5% on the sales of the business, with the first Rp 500 juta of the year free for an
 *     individual (PP 55/2022 Art. 60(2), kept by PP 20/2026);
 *   - the progressive tax (UU PPh Art. 17(1)(a)) on the NET income of services as an independent worker: gross
 *     services income less the costs of earning it, less PTKP, rounded down to whole thousands, taxed in layers.
 * Tax already withheld by clients and by the owner's own PT is a credit against the progressive tax.
 * Every rate, layer and PTKP amount comes from the published rule data the database returns; nothing is hard-coded
 * here, so a change of law is a new rule version and not a new release. Nothing is recorded: it is an estimate until
 * the year is settled, and monthly PPh 25 instalments are not modelled.
 */

export interface TaxLayer {
  /** Lower bound of the layer (inclusive). */
  from: string;
  /** Upper bound; null for the top layer. */
  to: string | null;
  rate: string;
  /** The part of the taxable income that falls in this layer. */
  amount: string;
  tax: string;
}

export interface ProgressiveResult {
  /** Gross services income: recorded in this book plus what the owner's PT paid. */
  gross: string;
  costs: string;
  /** Gross less costs, never below zero. */
  net: string;
  ptkpStatus: PtkpStatus;
  ptkpStatusChosen: boolean;
  ptkp: string;
  /** Net less PTKP, rounded down; zero when PTKP covers the net income. */
  taxable: string;
  layers: TaxLayer[];
  tax: string;
  credit: string;
  /** Tax less credit: positive is still to pay, negative is an overpayment. */
  balance: string;
  /** Tax as a share of the gross income, for the figure "x% dari pendapatan jasa". */
  effectiveRate: string;
  /** True when costs exceed the gross (a loss in the year). */
  loss: boolean;
}

export interface FinalResult {
  turnover: string;
  band: string;
  taxable: string;
  rate: string;
  tax: string;
  /** True while the whole turnover is still inside the free band. */
  insideBand: boolean;
  /** Turnover still free before tax starts. */
  bandLeft: string;
}

export interface CeilingResult {
  /** Turnover of this book and the owner's other books together. */
  total: string;
  ceiling: string;
  /** Share of the ceiling used, 0 to 1 (clamped), as a decimal text. */
  share: string;
  over: boolean;
  parts: { name: string; turnover: string; self: boolean }[];
}

export interface PersonalTaxResult {
  ready: boolean;
  /** Why the figures cannot be shown yet. */
  notReady: string | null;
  year: number;
  status: "running" | "settled";
  progressive: ProgressiveResult | null;
  final: FinalResult | null;
  ceiling: CeilingResult | null;
  /** Final plus progressive balance: the estimate of what the person owes for the year. */
  totalTax: string;
  /** What is still to pay after credits (final tax plus the progressive balance, never below zero). */
  totalToPay: string;
}

const ZERO = Decimal.zero();

function dec(text: string | null | undefined): Decimal {
  return text ? Decimal.parse(text) : ZERO;
}

/** PTKP amount of a status from the rule data; zero when the status is not in the rule. */
export function ptkpAmount(params: PersonalTariffParams, status: PtkpStatus): Decimal {
  return dec(params.ptkp[status]);
}

function toBig(value: Decimal): bigint {
  return BigInt(value.round(0, "down").toString());
}

/** Round a taxable income down to the step of the rule (whole thousands of rupiah). */
export function roundDownTo(value: Decimal, step: Decimal): Decimal {
  if (!step.isPositive()) return value.round(0, "down");
  const stepUnits = toBig(step);
  if (stepUnits <= BigInt(0)) return value.round(0, "down");
  const units = toBig(value);
  return Decimal.parse(((units / stepUnits) * stepUnits).toString());
}

/** The tax of a taxable income in layers; each layer is the part between the previous bound and its own. */
export function progressiveTax(
  taxable: Decimal,
  brackets: PersonalTariffParams["brackets"],
): { layers: TaxLayer[]; tax: Decimal } {
  const layers: TaxLayer[] = [];
  let tax = ZERO;
  let lower = ZERO;
  for (const bracket of brackets) {
    const upper = bracket.up_to === null ? null : Decimal.parse(bracket.up_to);
    const top = upper === null || taxable.cmp(upper) < 0 ? taxable : upper;
    const part = top.cmp(lower) > 0 ? top.sub(lower) : ZERO;
    const layerTax = part.mul(Decimal.parse(bracket.rate)).round(0, "half_up");
    layers.push({
      from: lower.toString(),
      to: upper === null ? null : upper.toString(),
      rate: bracket.rate,
      amount: part.toString(),
      tax: layerTax.toString(),
    });
    tax = tax.add(layerTax);
    if (upper === null || taxable.cmp(upper) <= 0) break;
    lower = upper;
  }
  return { layers, tax };
}

/** The progressive calculation on the net income of services. */
export function computeProgressive(
  summary: PersonalTaxSummary,
  params: PersonalTariffParams,
): ProgressiveResult {
  const gross = dec(summary.freelance.own_gross).add(dec(summary.freelance.pt_gross));
  const costs = dec(summary.costs.total);
  const loss = costs.cmp(gross) > 0;
  const net = loss ? ZERO : gross.sub(costs);
  const chosen = summary.ptkp_status;
  const status: PtkpStatus = chosen ?? "TK/0";
  const ptkp = ptkpAmount(params, status);
  const afterPtkp = net.cmp(ptkp) > 0 ? net.sub(ptkp) : ZERO;
  const taxable = roundDownTo(afterPtkp, dec(params.pkp_round_down_to));
  const { layers, tax } = progressiveTax(taxable, params.brackets);
  const credit = dec(summary.freelance.own_withheld).add(dec(summary.freelance.pt_withheld));
  const balance = tax.sub(credit);
  return {
    gross: gross.toString(),
    costs: costs.toString(),
    net: net.toString(),
    ptkpStatus: status,
    ptkpStatusChosen: chosen !== null,
    ptkp: ptkp.toString(),
    taxable: taxable.toString(),
    layers,
    tax: tax.toString(),
    credit: credit.toString(),
    balance: balance.toString(),
    effectiveRate: percentOf(tax, gross),
    loss,
  };
}

/** `part / whole` as a percent with up to two decimals, e.g. "2.5"; "0" when there is no whole. */
export function percentOf(part: Decimal, whole: Decimal): string {
  const w = toBig(whole);
  if (w <= BigInt(0)) return "0";
  const hundredths = (toBig(part) * BigInt(10000) + w / BigInt(2)) / w;
  const whole2 = hundredths / BigInt(100);
  const frac = (hundredths % BigInt(100)).toString().padStart(2, "0").replace(/0+$/, "");
  return frac ? `${whole2}.${frac}` : whole2.toString();
}

/** PPh Final UMKM on the sales of the business, with the free band of an individual. */
export function computeFinal(summary: PersonalTaxSummary, rate: string, band: string): FinalResult {
  const turnover = dec(summary.business.turnover);
  const bandD = dec(band);
  const taxable = turnover.cmp(bandD) > 0 ? turnover.sub(bandD) : ZERO;
  const tax = taxable.mul(Decimal.parse(rate)).round(0, "half_up");
  return {
    turnover: turnover.toString(),
    band: bandD.toString(),
    taxable: taxable.toString(),
    rate,
    tax: tax.toString(),
    insideBand: turnover.cmp(bandD) <= 0,
    bandLeft: (turnover.cmp(bandD) < 0 ? bandD.sub(turnover) : ZERO).toString(),
  };
}

/** The Rp 4,8 miliar ceiling counts this book and the owner's other books together. */
export function computeCeiling(summary: PersonalTaxSummary, ceiling: string): CeilingResult {
  const parts = [
    { name: "Buku Pribadi ini", turnover: summary.group.own_turnover, self: true },
    ...summary.group.others.map((o) => ({ name: o.name, turnover: o.turnover, self: false })),
  ];
  const total = parts.reduce((sum, p) => sum.add(dec(p.turnover)), ZERO);
  const ceilingD = dec(ceiling);
  const share =
    ceilingD.isPositive() && total.isPositive()
      ? Math.min(1, Number(total.toString()) / Number(ceilingD.toString()))
      : 0;
  return {
    total: total.toString(),
    ceiling: ceilingD.toString(),
    share: share.toString(),
    over: total.cmp(ceilingD) > 0,
    parts,
  };
}

export function computePersonalTax(summary: PersonalTaxSummary): PersonalTaxResult {
  const { final, tariff } = summary.rules;
  if (!tariff || !final) {
    return {
      ready: false,
      notReady: "Aturan tarif belum tersedia untuk tahun ini. Hubungi admin.",
      year: summary.year,
      status: summary.status,
      progressive: null,
      final: null,
      ceiling: null,
      totalTax: "0",
      totalToPay: "0",
    };
  }
  const progressive = computeProgressive(summary, tariff.params);
  const finalResult = computeFinal(
    summary,
    final.params.rate,
    final.params.exempt_band.individual ?? "0",
  );
  const ceiling = computeCeiling(summary, final.params.annual_ceiling);
  const totalTax = dec(progressive.tax).add(dec(finalResult.tax));
  const toPay = dec(progressive.balance).add(dec(finalResult.tax));
  return {
    ready: true,
    notReady: null,
    year: summary.year,
    status: summary.status,
    progressive,
    final: finalResult,
    ceiling,
    totalTax: totalTax.toString(),
    totalToPay: (toPay.isNegative() ? ZERO : toPay).toString(),
  };
}

/** Words for a PTKP status, e.g. "K/1" -> "Kawin, 1 tanggungan". */
export function ptkpLabel(status: PtkpStatus): string {
  const parts = status.split("/");
  const dependents = Number(parts[parts.length - 1]);
  const dep = dependents === 0 ? "tanpa tanggungan" : `${dependents} tanggungan`;
  if (status.startsWith("TK")) return `Tidak kawin, ${dep}`;
  if (status.startsWith("K/I")) return `Kawin, istri berpenghasilan, ${dep}`;
  return `Kawin, ${dep}`;
}

/** The combined turnover of this book and the owner's other books against the ceiling (Ringkasan of both). */
export function groupTurnoverView(
  group: {
    own_turnover: string;
    ceiling: string | null;
    others: { name: string; turnover: string }[];
  },
  ownName: string,
): CeilingResult | null {
  if (group.ceiling === null) return null;
  const parts = [
    { name: ownName, turnover: group.own_turnover, self: true },
    ...group.others.map((o) => ({ name: o.name, turnover: o.turnover, self: false })),
  ];
  const total = parts.reduce((sum, p) => sum.add(dec(p.turnover)), ZERO);
  const ceilingD = dec(group.ceiling);
  const share = ceilingD.isPositive()
    ? Math.min(1, Number(total.toString()) / Number(ceilingD.toString()))
    : 0;
  return {
    total: total.toString(),
    ceiling: ceilingD.toString(),
    share: share.toString(),
    over: total.cmp(ceilingD) > 0,
    parts,
  };
}
