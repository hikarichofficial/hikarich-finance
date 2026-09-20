/**
 * Exact decimal arithmetic for money (Step 13 §25, Step 04 §14).
 *
 * Amounts are integers of an implicit power-of-ten scale held in a BigInt, so no binary floating point is
 * ever involved. PostgreSQL `numeric` stays the authoritative engine for stored figures; this class exists
 * so the application can validate, display and pre-check amounts (for example "does this journal balance
 * before I send it") with exactly the same rounding semantics as `app_private.round_amount` /
 * `allocate_amount` in the database.
 */

export type RoundingMode = "half_up" | "half_even" | "down" | "up";

export const ROUNDING_MODES: readonly RoundingMode[] = ["half_up", "half_even", "down", "up"];

/** Plain decimal text: optional minus, digits, optional fraction. No exponent, no spaces, no separators. */
const DECIMAL_PATTERN = /^(-?)(\d+)(?:\.(\d+))?$/;

/** Upper bound on the number of fraction digits we accept from outside (the database stores 4). */
const MAX_PARSE_SCALE = 18;

// BigInt literals (like `0` followed by n) need a newer compile target than this project's tsconfig; named constants avoid it.
const ZERO = BigInt(0);
const ONE = BigInt(1);
const TWO = BigInt(2);
const TEN = BigInt(10);

function pow10(exponent: number): bigint {
  return TEN ** BigInt(exponent);
}

export class DecimalError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DecimalError";
  }
}

export class Decimal {
  /** value = units / 10^scale */
  private constructor(
    readonly units: bigint,
    readonly scale: number,
  ) {}

  static zero(scale = 0): Decimal {
    return new Decimal(ZERO, scale);
  }

  /** Parses plain decimal text. Anything else (floats as numbers, exponents, "1,000") is rejected. */
  static parse(text: string): Decimal {
    if (typeof text !== "string") throw new DecimalError("Decimal must be parsed from text");
    const match = DECIMAL_PATTERN.exec(text);
    if (!match) throw new DecimalError(`Not a plain decimal number: "${text}"`);
    const [, sign, whole, fraction = ""] = match;
    if (fraction.length > MAX_PARSE_SCALE) throw new DecimalError("Too many fraction digits");
    const units = BigInt(`${whole}${fraction}`);
    return new Decimal(sign === "-" ? -units : units, fraction.length);
  }

  /** Like parse(), but returns null instead of throwing (for validation code that reports its own issues). */
  static tryParse(text: string | undefined): Decimal | null {
    if (text === undefined) return null;
    try {
      return Decimal.parse(text);
    } catch (error) {
      if (error instanceof DecimalError) return null;
      throw error;
    }
  }

  /** Exact conversion from an integer number of whole units (safe integers only). */
  static fromInteger(value: number): Decimal {
    if (!Number.isSafeInteger(value)) throw new DecimalError("Only safe integers can be converted");
    return new Decimal(BigInt(value), 0);
  }

  static fromUnits(units: bigint, scale: number): Decimal {
    if (!Number.isInteger(scale) || scale < 0 || scale > 30)
      throw new DecimalError("Invalid scale");
    return new Decimal(units, scale);
  }

  private aligned(other: Decimal): [bigint, bigint, number] {
    const scale = Math.max(this.scale, other.scale);
    return [
      this.units * pow10(scale - this.scale),
      other.units * pow10(scale - other.scale),
      scale,
    ];
  }

  add(other: Decimal): Decimal {
    const [a, b, scale] = this.aligned(other);
    return new Decimal(a + b, scale);
  }

  sub(other: Decimal): Decimal {
    const [a, b, scale] = this.aligned(other);
    return new Decimal(a - b, scale);
  }

  /** Exact product; the result carries scale(a)+scale(b) until rounded. */
  mul(other: Decimal): Decimal {
    return new Decimal(this.units * other.units, this.scale + other.scale);
  }

  negate(): Decimal {
    return new Decimal(-this.units, this.scale);
  }

  abs(): Decimal {
    return this.units < ZERO ? this.negate() : this;
  }

  /** -1, 0 or 1. */
  cmp(other: Decimal): -1 | 0 | 1 {
    const [a, b] = this.aligned(other);
    return a < b ? -1 : a > b ? 1 : 0;
  }

  eq(other: Decimal): boolean {
    return this.cmp(other) === 0;
  }

  isZero(): boolean {
    return this.units === ZERO;
  }

  isNegative(): boolean {
    return this.units < ZERO;
  }

  isPositive(): boolean {
    return this.units > ZERO;
  }

  /**
   * Rounds to `scale` fraction digits. Semantics match the database (`app_private.round_amount`):
   *   half_up   ties away from zero (default for documents and tax lines)
   *   half_even ties to the even neighbour
   *   down      truncates toward zero
   *   up        away from zero whenever anything is dropped
   */
  round(scale: number, mode: RoundingMode = "half_up"): Decimal {
    if (!Number.isInteger(scale) || scale < 0 || scale > 10) {
      throw new DecimalError("Rounding scale must be between 0 and 10");
    }
    if (!ROUNDING_MODES.includes(mode)) throw new DecimalError(`Unknown rounding mode ${mode}`);
    if (this.scale <= scale) return new Decimal(this.units * pow10(scale - this.scale), scale);

    const divisor = pow10(this.scale - scale);
    const negative = this.units < ZERO;
    const magnitude = negative ? -this.units : this.units;
    let quotient = magnitude / divisor;
    const remainder = magnitude % divisor;
    const twice = remainder * TWO;

    switch (mode) {
      case "down":
        break;
      case "up":
        if (remainder > ZERO) quotient += ONE;
        break;
      case "half_up":
        if (twice >= divisor) quotient += ONE;
        break;
      case "half_even":
        if (twice > divisor || (twice === divisor && quotient % TWO === ONE)) quotient += ONE;
        break;
    }
    return new Decimal(negative ? -quotient : quotient, scale);
  }

  /** True when the value has no digits beyond `scale` (so rounding to `scale` would change nothing). */
  fitsScale(scale: number): boolean {
    return this.round(scale, "down").eq(this);
  }

  /** Canonical text with exactly `this.scale` fraction digits. */
  toString(): string {
    const negative = this.units < ZERO;
    const digits = (negative ? -this.units : this.units).toString().padStart(this.scale + 1, "0");
    const whole = digits.slice(0, digits.length - this.scale);
    const fraction = this.scale > 0 ? `.${digits.slice(digits.length - this.scale)}` : "";
    return `${negative && this.units !== ZERO ? "-" : ""}${whole}${fraction}`;
  }

  /** Text with exactly `scale` fraction digits, rounding first (half_up by default). */
  toFixed(scale: number, mode: RoundingMode = "half_up"): string {
    return this.round(scale, mode).toString();
  }
}

export function sumDecimals(values: readonly Decimal[]): Decimal {
  return values.reduce((total, value) => total.add(value), Decimal.zero());
}

/**
 * Splits `total` across `weights` with the largest-remainder method so the parts add up to the total
 * exactly (no unit is created or lost). Ties on the remainder go to the earliest position. Mirrors
 * `app_private.allocate_amount`.
 */
export function allocate(total: Decimal, weights: readonly number[], scale: number): Decimal[] {
  if (weights.length === 0) throw new DecimalError("At least one weight is required");
  if (weights.some((w) => !Number.isSafeInteger(w) || w < 0)) {
    throw new DecimalError("Weights must be non-negative safe integers");
  }
  const weightSum = weights.reduce((a, b) => a + b, 0);
  if (weightSum <= 0) throw new DecimalError("Weights must not all be zero");
  if (!total.fitsScale(scale))
    throw new DecimalError("Total has more decimals than the allocation scale");

  const negative = total.isNegative();
  // fitsScale() held, so truncating to `scale` is exact and the result carries exactly `scale` digits.
  const totalUnits = total.abs().round(scale, "down").units;

  const sum = BigInt(weightSum);
  const base: bigint[] = [];
  const remainders: bigint[] = [];
  let assigned = ZERO;
  for (const weight of weights) {
    const product = totalUnits * BigInt(weight);
    const floor = product / sum;
    base.push(floor);
    remainders.push(product % sum);
    assigned += floor;
  }

  let left = totalUnits - assigned;
  const taken = new Set<number>();
  while (left > ZERO) {
    let best = -1;
    for (let i = 0; i < weights.length; i += 1) {
      if (weights[i] === 0 || taken.has(i)) continue;
      if (best === -1 || remainders[i] > remainders[best]) best = i;
    }
    base[best] += ONE;
    taken.add(best);
    left -= ONE;
  }

  return base.map((part) => Decimal.fromUnits(negative ? -part : part, scale));
}
