/**
 * Command Menu quick-create registry (P13 Part 4, eleventh increment; Step 09 §7/Step 10 §18, DECISIONS
 * 199). Before building this, the OWNER was asked whether to start it at all: most modules (invoices,
 * bills, loans, obligations, equity, assets, and more) have no create form/UI yet -- every one of those
 * flows is still deferred in earlier decisions. The OWNER chose to ship it now, scoped to exactly the
 * four `/new` routes that already exist, rather than wait for the rest: Transfer Uang (`money.transfer_
 * create`), Anggaran (`planning.budget_edit`), Aturan Berulang (`planning.recurring_edit`) and Target
 * Pendapatan (`planning.budget_edit` again -- Revenue Target reuses Budget's own edit permission, the
 * same choice decision 185 already made for the Target screen's read side). This registry is meant to
 * grow: a future increment that ships a new `/new` route adds one entry here, nothing else.
 *
 * Deliberately a single required `permission: string` per item, not `NavItem`'s own `permission?:
 * readonly string[]` "any of these" array (`src/domain/shell/navigation.ts`) -- every quick-create
 * target here gates its `/new` route on exactly one `requirePermission(...)` call (confirmed directly
 * against each page: `src/app/(app)/money/transfers/new/page.tsx`, `.../planning/budgets/new/page.tsx`,
 * `.../planning/recurring/new/page.tsx`, `.../planning/targets/new/page.tsx`), never a compound or
 * OR-permission rule the way some nav items approximate (decisions 180/181/182); a plain single string
 * says exactly what the gate is, with nothing to approximate.
 */

export interface QuickCreateItem {
  readonly label: string;
  readonly href: string;
  readonly permission: string;
}

export const QUICK_CREATE_REGISTRY: readonly QuickCreateItem[] = [
  {
    label: "Transfer Uang Baru",
    href: "/money/transfers/new",
    permission: "money.transfer_create",
  },
  { label: "Anggaran Baru", href: "/planning/budgets/new", permission: "planning.budget_edit" },
  {
    label: "Aturan Berulang Baru",
    href: "/planning/recurring/new",
    permission: "planning.recurring_edit",
  },
  {
    label: "Target Pendapatan Baru",
    href: "/planning/targets/new",
    permission: "planning.budget_edit",
  },
];

/**
 * Filters the registry down to what this membership may actually reach (the same "unavailable by
 * permission is omitted, never shown as a dead control" rule `visibleNavigation` already follows for the
 * Sidebar/Command Menu's navigation group). Order is preserved -- the registry's own declared order. */
export function visibleQuickCreate(permissions: readonly string[]): QuickCreateItem[] {
  return QUICK_CREATE_REGISTRY.filter((item) => permissions.includes(item.permission));
}
