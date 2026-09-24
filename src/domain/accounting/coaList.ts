import type { LedgerAccountRow } from "@/schemas/accounting";

/**
 * Pure helpers for the Chart of Accounts screen (P13 Part 3d, Step 09 §14: "COA uses hierarchical tree/list
 * with search, account status and protected-control indicators"). `public.ledger_accounts` is seeded once
 * from `coa_templates`/`coa_template_accounts` at Entity setup (P1) and has no create/edit RPC at all yet --
 * this screen is a read, matching the spec's own wording (a list to browse, not a builder).
 */

export interface CoaListRow {
  account: LedgerAccountRow;
  depth: number;
}

function byParent(accounts: readonly LedgerAccountRow[]): Map<string | null, LedgerAccountRow[]> {
  const map = new Map<string | null, LedgerAccountRow[]>();
  for (const account of accounts) {
    const list = map.get(account.parent_id) ?? [];
    list.push(account);
    map.set(account.parent_id, list);
  }
  for (const list of map.values()) list.sort((a, b) => a.code.localeCompare(b.code));
  return map;
}

function ancestorsOf(accountId: string, byId: ReadonlyMap<string, LedgerAccountRow>): Set<string> {
  const result = new Set<string>();
  let current = byId.get(accountId);
  while (current?.parent_id) {
    result.add(current.parent_id);
    current = byId.get(current.parent_id);
  }
  return result;
}

/** Flattens the chart of accounts into a depth-first, code-ordered list for a hierarchical tree/list render.
 * `included`, when given, restricts which accounts are shown -- but an ancestor of an included account is
 * always kept too (even if it does not itself match), so a search match never loses its place in the tree;
 * omit it to show every account. */
export function buildCoaTree(
  accounts: readonly LedgerAccountRow[],
  included?: ReadonlySet<string>,
): CoaListRow[] {
  const byId = new Map(accounts.map((a) => [a.id, a]));
  let keep: ReadonlySet<string> | undefined = included;
  if (included) {
    const withAncestors = new Set(included);
    for (const id of included) {
      for (const ancestor of ancestorsOf(id, byId)) withAncestors.add(ancestor);
    }
    keep = withAncestors;
  }
  const children = byParent(accounts);
  const result: CoaListRow[] = [];
  function walk(parentId: string | null, depth: number): void {
    for (const account of children.get(parentId) ?? []) {
      if (!keep || keep.has(account.id)) {
        result.push({ account, depth });
        walk(account.id, depth + 1);
      }
    }
  }
  walk(null, 0);
  return result;
}

export type CoaStatusFilter = "active" | "inactive";

export interface CoaStatusFilterOption {
  value: CoaStatusFilter | null;
  label: string;
}

export const COA_STATUS_FILTER_OPTIONS: readonly CoaStatusFilterOption[] = [
  { value: null, label: "Semua" },
  { value: "active", label: "Aktif" },
  { value: "inactive", label: "Tidak Aktif" },
];

export function matchesCoaStatus(
  account: LedgerAccountRow,
  status: CoaStatusFilter | null,
): boolean {
  return status === null || account.status === status;
}

export function parseCoaStatusFilter(value: string | undefined): CoaStatusFilter | undefined {
  return value === "active" || value === "inactive" ? value : undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesCoaQuery(account: LedgerAccountRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return normalize(account.code).includes(needle) || normalize(account.name).includes(needle);
}

/** The account ids that should stay visible under the current status/search filters, for `buildCoaTree`'s
 * `included` parameter -- `undefined` (no filter active) short-circuits `buildCoaTree` back to showing every
 * account, rather than paying for the ancestor walk when nothing is actually filtered out. */
export function coaVisibleIds(
  accounts: readonly LedgerAccountRow[],
  status: CoaStatusFilter | null,
  query: string,
): Set<string> | undefined {
  if (status === null && query.trim() === "") return undefined;
  const matches = accounts.filter((a) => matchesCoaStatus(a, status) && matchesCoaQuery(a, query));
  return new Set(matches.map((a) => a.id));
}

export const ACCOUNT_CLASS_LABELS: Record<string, string> = {
  asset: "Aset",
  liability: "Liabilitas",
  equity: "Ekuitas",
  revenue: "Pendapatan",
  expense: "Beban",
};

export function accountClassLabel(accountClass: string): string {
  return ACCOUNT_CLASS_LABELS[accountClass] ?? accountClass;
}

export interface CoaIndicator {
  text: string;
  tone: "neutral" | "attention";
}

/** Step 09 §14's "protected-control indicators": a group header cannot receive any posting at all; a control
 * account (`is_control`, e.g. the AR/AP summary accounts sub-ledgers reconcile against) is not meant for
 * direct use either; a "protected" leaf account (`!allows_manual_posting`) accepts only system postings
 * unless a manual journal supplies an authorized override reason (Step 04 §2, confirmed in
 * `app_private.normalise_lines`'s own check). */
export function coaIndicators(account: LedgerAccountRow): CoaIndicator[] {
  const indicators: CoaIndicator[] = [];
  if (account.is_group) indicators.push({ text: "Grup", tone: "neutral" });
  if (account.is_control) indicators.push({ text: "Akun Kontrol", tone: "attention" });
  if (!account.is_group && !account.allows_manual_posting) {
    indicators.push({ text: "Dilindungi", tone: "attention" });
  }
  return indicators;
}
