/**
 * The primary sitemap (Step 09 §3, Table "Primary Sitemap"), as pure data: one entry per primary menu
 * item, each carrying the permission that must be held in the active Entity before it is shown at all
 * (Step 09 §4: "unavailable by permission are omitted rather than shown as dead controls"), and its
 * submenu destinations. This is the single source of truth for both the Sidebar (P13 Part 1) and the
 * Command Menu's "Navigate" group (P13 Part 4) -- the IA is fixed here exactly once, never duplicated.
 *
 * Every `href` beyond `/` resolves through `src/app/(app)/[...slug]/page.tsx` until its own screen ships
 * in a later P13 part (Step 09 §28: the shell/IA is built first, screens fill in progressively) --
 * Next.js prefers a more specific route once one exists at that path, so nothing here needs to change
 * when that happens.
 */

/** Lucide icon component names used by the Sidebar (Step 09 §4: collapsed icon mode). Kept as a
 * string key here so this file stays a pure data module with no React/icon-library import. */
export type NavIconName =
  | "LayoutDashboard"
  | "ShoppingCart"
  | "Receipt"
  | "Wallet"
  | "BookOpen"
  | "Landmark"
  | "Building2"
  | "Users"
  | "Target"
  | "BarChart3"
  | "FolderOpen"
  | "Settings";

export interface NavItem {
  readonly label: string;
  readonly href: string;
  /** A membership needs ANY of these permissions (module `.view` grants are typically singular, but
   * Assets & Financing spans three independent capabilities). Omitted for links visible to every
   * signed-in member of the Entity (e.g. Overview). */
  readonly permission?: readonly string[];
}

export interface NavGroup {
  readonly key: string;
  readonly label: string;
  readonly href: string;
  readonly permission?: readonly string[];
  readonly items?: readonly NavItem[];
  readonly icon: NavIconName;
}

export const NAVIGATION: readonly NavGroup[] = [
  {
    key: "overview",
    icon: "LayoutDashboard",
    label: "Overview",
    href: "/",
    items: [
      { label: "Dashboard", href: "/" },
      { label: "Cash & Bank Snapshot", href: "/money/accounts", permission: ["money.view"] },
      { label: "Recent Activity", href: "/activity" },
    ],
  },
  {
    key: "sales",
    icon: "ShoppingCart",
    label: "Sales",
    href: "/sales/invoices",
    permission: ["invoices.view"],
    items: [
      { label: "Invoices", href: "/sales/invoices", permission: ["invoices.view"] },
      { label: "Payments Received", href: "/sales/payments", permission: ["invoices.view"] },
      { label: "Refunds", href: "/sales/refunds", permission: ["refunds.view"] },
      { label: "Customers", href: "/sales/customers", permission: ["contacts.view"] },
      { label: "Products & Services", href: "/sales/products", permission: ["products.view"] },
    ],
  },
  {
    key: "purchases",
    icon: "Receipt",
    label: "Purchases",
    href: "/purchases/bills",
    permission: ["bills.view"],
    items: [
      { label: "Bills", href: "/purchases/bills", permission: ["bills.view"] },
      { label: "Expenses", href: "/purchases/expenses", permission: ["bills.view"] },
      { label: "Payments Made", href: "/purchases/payments", permission: ["bills.view"] },
      { label: "Vendors", href: "/purchases/vendors", permission: ["contacts.view"] },
    ],
  },
  {
    key: "money",
    icon: "Wallet",
    label: "Money",
    href: "/money/accounts",
    permission: ["money.view"],
    items: [
      { label: "Accounts", href: "/money/accounts" },
      { label: "Transfers", href: "/money/transfers" },
      { label: "Reconciliation", href: "/money/reconciliation" },
      { label: "Cash/Bank Activity", href: "/money/activity" },
    ],
  },
  {
    key: "accounting",
    icon: "BookOpen",
    label: "Accounting",
    href: "/accounting/journal",
    permission: ["accounting.view"],
    items: [
      { label: "Journal", href: "/accounting/journal" },
      { label: "Chart of Accounts", href: "/accounting/coa" },
      { label: "Accounting Periods", href: "/accounting/periods" },
      { label: "Opening Balances", href: "/accounting/opening-balances" },
      { label: "Advanced Adjustments", href: "/accounting/adjustments" },
    ],
  },
  {
    key: "tax",
    icon: "Landmark",
    label: "Tax",
    href: "/tax",
    permission: ["tax.view"],
    items: [
      { label: "Tax Overview", href: "/tax" },
      { label: "Tax Ledger", href: "/tax/ledger" },
      { label: "PPh Final / Income Tax", href: "/tax/pph" },
      { label: "Withholding", href: "/tax/withholding" },
      { label: "PPN", href: "/tax/ppn" },
      { label: "Tax Calendar", href: "/tax/calendar" },
      { label: "Filing & Evidence", href: "/tax/filing" },
      { label: "Tax Rules / Configuration", href: "/tax/rules" },
    ],
  },
  {
    key: "assets-financing",
    icon: "Building2",
    label: "Assets & Financing",
    href: "/assets",
    permission: ["assets.view", "loans.view", "equity.view"],
    items: [
      { label: "Assets", href: "/assets", permission: ["assets.view"] },
      { label: "Depreciation", href: "/assets/depreciation", permission: ["assets.view"] },
      { label: "Loans", href: "/assets/loans", permission: ["loans.view"] },
      {
        label: "Other Receivables",
        href: "/assets/other-receivables",
        permission: ["loans.view"],
      },
      { label: "Other Payables", href: "/assets/other-payables", permission: ["loans.view"] },
      { label: "Capital & Equity", href: "/assets/equity", permission: ["equity.view"] },
    ],
  },
  {
    key: "payroll",
    icon: "Users",
    label: "Payroll",
    href: "/payroll/employees",
    permission: ["payroll.employee_view"],
    items: [
      { label: "Employees", href: "/payroll/employees" },
      {
        label: "Payroll Runs",
        href: "/payroll/runs",
        // `payroll_run_list`/`payroll_run_get` need `payroll.compensation_view` AND (`payroll.run` OR
        // `payroll.approve` OR `payroll.pay`) -- a compound rule this OR-only permission array cannot fully
        // express (decision 180). `payroll.compensation_view` is the one component the RPC always requires,
        // so declaring it here is the closest match available, same "primary gate" fix decision 176 made for
        // Other Receivables/Payables when the nav's own permission didn't match the RPC's.
        permission: ["payroll.compensation_view"],
      },
      {
        label: "Payslips",
        href: "/payroll/payslips",
        // `payroll_payslip_list`/`payroll_payslip_get` share the exact same compound rule as Payroll Runs
        // above -- same fix, same residual imperfection (decision 181).
        permission: ["payroll.compensation_view"],
      },
      {
        label: "Payroll Tax & Liabilities",
        href: "/payroll/tax",
        // Was `payroll.tax_view` -- wrong on its own: `payroll_liability_report` (the screen's own "always
        // visible" section) needs only the base compound rule (`payroll.compensation_view` AND run/approve/
        // pay), not `tax_view` at all, while `payroll_annual_reconciliation`/`payroll_employee_tax_ledger`
        // hard-require `tax_view` on top of that base rule (decision 182). `payroll.compensation_view` is
        // kept as the closer single-permission match, the same choice made for Payroll Runs/Payslips above,
        // since a `tax_view`-only holder without the base rule would see a nav entry that fails immediately,
        // whereas a `compensation_view` holder without `tax_view` still sees a working page (just without
        // the two tax-gated sections) -- the same documented residual imperfection as above.
        permission: ["payroll.compensation_view"],
      },
    ],
  },
  {
    key: "planning",
    icon: "Target",
    label: "Planning",
    href: "/planning/budgets",
    permission: ["planning.view"],
    items: [
      { label: "Budgets", href: "/planning/budgets" },
      { label: "Targets", href: "/planning/targets" },
      { label: "Forecasts", href: "/planning/forecasts" },
      { label: "Recurring Rules", href: "/planning/recurring" },
    ],
  },
  {
    key: "reports",
    icon: "BarChart3",
    label: "Reports",
    href: "/reports",
    permission: ["reports.view"],
    items: [
      { label: "Financial Reports", href: "/reports" },
      { label: "Sales / Purchase", href: "/reports/sales-purchase" },
      { label: "Cashflow", href: "/reports/cashflow" },
      { label: "Tax", href: "/reports/tax" },
      { label: "Payroll", href: "/reports/payroll" },
      { label: "Assets / Loans", href: "/reports/assets-loans" },
      { label: "Custom Reports", href: "/reports/custom" },
      { label: "Saved Reports", href: "/reports/saved" },
    ],
  },
  {
    key: "documents",
    icon: "FolderOpen",
    label: "Documents",
    href: "/documents",
    permission: ["documents.view"],
    items: [
      { label: "Documents Center", href: "/documents" },
      { label: "Uploads", href: "/documents/uploads" },
      { label: "Linked Evidence", href: "/documents/evidence" },
      { label: "Archive", href: "/documents/archive" },
    ],
  },
  {
    key: "administration",
    icon: "Settings",
    label: "Administration",
    href: "/admin/settings",
    permission: ["settings.view", "audit.view", "system.import"],
    items: [
      { label: "Imports", href: "/admin/imports", permission: ["system.import"] },
      { label: "Audit Log", href: "/admin/audit", permission: ["audit.view"] },
      { label: "Users & Roles", href: "/admin/users", permission: ["settings.view"] },
      { label: "Settings", href: "/admin/settings", permission: ["settings.view"] },
      { label: "Security", href: "/admin/security", permission: ["settings.view"] },
      { label: "Backup & Restore", href: "/admin/backup", permission: ["settings.view"] },
    ],
  },
];

function hasAny(granted: readonly string[], required: readonly string[] | undefined): boolean {
  if (!required || required.length === 0) return true;
  return required.some((permission) => granted.includes(permission));
}

/**
 * Filters the fixed sitemap down to what this membership may see (Step 09 §4). A group survives if
 * its own gate passes OR at least one of its items' gates passes; each surviving group keeps only its
 * visible items. Order is preserved -- the sitemap's order IS the product hierarchy (Step 09 §29).
 */
export function visibleNavigation(permissions: readonly string[]): NavGroup[] {
  const result: NavGroup[] = [];
  for (const group of NAVIGATION) {
    const items: readonly NavItem[] | undefined = group.items?.filter((item) =>
      hasAny(permissions, item.permission),
    );
    const groupVisible = hasAny(permissions, group.permission) || (items?.length ?? 0) > 0;
    if (groupVisible) result.push({ ...group, items });
  }
  return result;
}
