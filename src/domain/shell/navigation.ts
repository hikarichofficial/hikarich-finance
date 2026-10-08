/**
 * The primary sitemap (Step 09 §3, Table "Primary Sitemap"), as pure data (labels in Indonesian since
 * OWNER decision 254; the structure, order, routes and permissions are the sitemap's own): one entry per primary menu
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
  | "Settings"
  | "BookMarked";

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
    label: "Ringkasan",
    href: "/",
    items: [
      { label: "Dashboard", href: "/" },
      { label: "Saldo Kas & Bank", href: "/cash-snapshot", permission: ["money.view"] },
      { label: "Aktivitas Terbaru", href: "/activity" },
    ],
  },
  {
    key: "sales",
    icon: "ShoppingCart",
    label: "Penjualan",
    href: "/sales/invoices",
    permission: ["invoices.view"],
    items: [
      { label: "Invoice", href: "/sales/invoices", permission: ["invoices.view"] },
      { label: "Pembayaran Diterima", href: "/sales/payments", permission: ["invoices.view"] },
      { label: "Klaim Pembayaran", href: "/sales/claims", permission: ["invoices.view"] },
      { label: "Catat Pendapatan", href: "/sales/income", permission: ["invoices.view"] },
      { label: "Marketplace", href: "/sales/marketplace", permission: ["invoices.view"] },
      { label: "Tautan Pembayaran", href: "/sales/payment-links", permission: ["invoices.view"] },
      { label: "Pengembalian Dana", href: "/sales/refunds", permission: ["refunds.view"] },
      { label: "Pelanggan", href: "/sales/customers", permission: ["contacts.view"] },
      { label: "Produk & Jasa", href: "/sales/products", permission: ["products.view"] },
    ],
  },
  {
    key: "purchases",
    icon: "Receipt",
    label: "Pembelian",
    href: "/purchases/bills",
    permission: ["bills.view"],
    items: [
      { label: "Tagihan", href: "/purchases/bills", permission: ["bills.view"] },
      { label: "Beban", href: "/purchases/expenses", permission: ["bills.view"] },
      { label: "Pembayaran Keluar", href: "/purchases/payments", permission: ["bills.view"] },
      { label: "Vendor", href: "/purchases/vendors", permission: ["contacts.view"] },
    ],
  },
  {
    key: "money",
    icon: "Wallet",
    label: "Kas & Bank",
    href: "/money/accounts",
    permission: ["money.view"],
    items: [
      { label: "Rekening", href: "/money/accounts" },
      { label: "Transfer", href: "/money/transfers" },
      { label: "Rekonsiliasi Bank", href: "/money/reconciliation" },
      { label: "Mutasi Kas & Bank", href: "/money/activity" },
    ],
  },
  {
    key: "accounting",
    icon: "BookOpen",
    label: "Akuntansi",
    href: "/accounting/journal",
    permission: ["accounting.view"],
    items: [
      { label: "Jurnal", href: "/accounting/journal" },
      { label: "Rekening Koran", href: "/accounting/statement" },
      { label: "Daftar Akun", href: "/accounting/coa" },
      { label: "Kategori", href: "/accounting/categories" },
      { label: "Periode Akuntansi", href: "/accounting/periods" },
      { label: "Saldo Awal", href: "/accounting/opening-balances" },
      { label: "Penyesuaian Lanjutan", href: "/accounting/adjustments" },
    ],
  },
  {
    key: "tax",
    icon: "Landmark",
    label: "Pajak",
    href: "/tax",
    permission: ["tax.view"],
    items: [
      { label: "Ringkasan Pajak", href: "/tax" },
      { label: "Buku Pajak", href: "/tax/ledger" },
      { label: "PPh Final", href: "/tax/pph" },
      { label: "Pemotongan PPh", href: "/tax/withholding" },
      { label: "PPN", href: "/tax/ppn" },
      { label: "Kalender Pajak", href: "/tax/calendar" },
      { label: "Pelaporan & Bukti", href: "/tax/filing" },
      { label: "Aturan Pajak", href: "/tax/rules" },
      { label: "Pengaturan Pajak", href: "/tax/setup" },
    ],
  },
  {
    key: "assets-financing",
    icon: "Building2",
    label: "Aset & Pendanaan",
    href: "/assets",
    permission: ["assets.view", "loans.view", "equity.view"],
    items: [
      { label: "Aset Tetap", href: "/assets", permission: ["assets.view"] },
      { label: "Penyusutan", href: "/assets/depreciation", permission: ["assets.view"] },
      { label: "Pinjaman", href: "/assets/loans", permission: ["loans.view"] },
      {
        label: "Piutang Lain",
        href: "/assets/other-receivables",
        permission: ["loans.view"],
      },
      { label: "Utang Lain", href: "/assets/other-payables", permission: ["loans.view"] },
      { label: "Modal & Ekuitas", href: "/assets/equity", permission: ["equity.view"] },
    ],
  },
  {
    key: "payroll",
    icon: "Users",
    label: "Payroll",
    href: "/payroll/employees",
    permission: ["payroll.employee_view"],
    items: [
      { label: "Karyawan", href: "/payroll/employees" },
      {
        label: "Proses Payroll",
        href: "/payroll/runs",
        // `payroll_run_list`/`payroll_run_get` need `payroll.compensation_view` AND (`payroll.run` OR
        // `payroll.approve` OR `payroll.pay`) -- a compound rule this OR-only permission array cannot fully
        // express (decision 180). `payroll.compensation_view` is the one component the RPC always requires,
        // so declaring it here is the closest match available, same "primary gate" fix decision 176 made for
        // Other Receivables/Payables when the nav's own permission didn't match the RPC's.
        permission: ["payroll.compensation_view"],
      },
      {
        label: "Slip Gaji",
        href: "/payroll/payslips",
        // `payroll_payslip_list`/`payroll_payslip_get` share the exact same compound rule as Payroll Runs
        // above -- same fix, same residual imperfection (decision 181).
        permission: ["payroll.compensation_view"],
      },
      {
        label: "Pajak & Kewajiban Payroll",
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
    label: "Perencanaan",
    href: "/planning/budgets",
    permission: ["planning.view"],
    items: [
      { label: "Anggaran", href: "/planning/budgets" },
      { label: "Target Pendapatan", href: "/planning/targets" },
      { label: "Perkiraan", href: "/planning/forecasts" },
      { label: "Transaksi Berulang", href: "/planning/recurring" },
    ],
  },
  {
    key: "reports",
    icon: "BarChart3",
    label: "Laporan",
    href: "/reports",
    permission: ["reports.view"],
    items: [
      { label: "Laporan Keuangan", href: "/reports" },
      { label: "Penjualan & Pembelian", href: "/reports/sales-purchase" },
      { label: "Arus Kas", href: "/reports/cashflow" },
      { label: "Pajak", href: "/reports/tax" },
      { label: "Payroll", href: "/reports/payroll" },
      { label: "Aset & Pinjaman", href: "/reports/assets-loans" },
      { label: "Laporan Kustom", href: "/reports/custom" },
      { label: "Laporan Tersimpan", href: "/reports/saved" },
    ],
  },
  {
    key: "documents",
    icon: "FolderOpen",
    label: "Dokumen",
    href: "/documents",
    permission: ["documents.view"],
    items: [
      { label: "Pusat Dokumen", href: "/documents" },
      { label: "Unggahan", href: "/documents/uploads" },
      { label: "Bukti Terkait", href: "/documents/evidence" },
      { label: "Arsip", href: "/documents/archive" },
    ],
  },
  {
    key: "administration",
    icon: "Settings",
    label: "Administrasi",
    href: "/admin/settings",
    permission: [
      "settings.view",
      "products.sku_settings",
      "audit.view",
      "users.view",
      "security.view",
      "system.import",
      "backup.create",
      "backup.restore",
    ],
    items: [
      { label: "Impor Data", href: "/admin/imports", permission: ["system.import"] },
      { label: "Jejak Audit", href: "/admin/audit", permission: ["audit.view"] },
      { label: "Pengguna & Peran", href: "/admin/users", permission: ["users.view"] },
      { label: "Pengaturan", href: "/admin/settings", permission: ["settings.view"] },
      { label: "Tampilan Invoice", href: "/admin/invoice-layout", permission: ["settings.view"] },
      { label: "Konfigurasi SKU", href: "/admin/sku", permission: ["products.sku_settings"] },
      { label: "Keamanan", href: "/admin/security", permission: ["security.view"] },
      {
        label: "Backup & Restore",
        href: "/admin/backup",
        permission: ["backup.create", "backup.restore"],
      },
    ],
  },
  {
    // Decision 299: the step-by-step guide, open to every signed-in member (no permission gate) so anyone
    // who needs "how do I ..." can read it. Its screenshots may show real data, so they are served only to
    // signed-in people (see the image route).
    key: "guide",
    icon: "BookMarked",
    label: "Panduan",
    href: "/guide",
    items: [
      { label: "Semua Panduan", href: "/guide" },
      { label: "Alur Kerja (Diagram)", href: "/guide/alur-kerja" },
    ],
  },
];

function hasAny(granted: readonly string[], required: readonly string[] | undefined): boolean {
  if (!required || required.length === 0) return true;
  return required.some((permission) => granted.includes(permission));
}

/**
 * Filters the fixed sitemap down to what this membership may see (Step 09 §4). An item is visible when
 * its own gate passes (or, having none, its menu's gate); a menu survives when at least one of its items
 * is visible, and keeps only those. Order is preserved -- the sitemap's order IS the product hierarchy (Step 09 §29).
 */
export function visibleNavigation(permissions: readonly string[]): NavGroup[] {
  const result: NavGroup[] = [];
  for (const group of NAVIGATION) {
    // An item without its own gate inherits its menu's gate (decision 254: before this, such items made
    // their menu appear for people who could not open any of its pages).
    const items: readonly NavItem[] | undefined = group.items?.filter((item) =>
      hasAny(permissions, item.permission ?? group.permission),
    );
    const groupVisible = group.items
      ? (items?.length ?? 0) > 0
      : hasAny(permissions, group.permission);
    if (groupVisible) result.push({ ...group, items });
  }
  return result;
}

/**
 * The nav item the current path belongs to: the item whose `href` is the path itself or its longest
 * path-segment prefix (so `/sales/invoices/123` marks "Invoice" and its group, decision 254). `/` only
 * matches itself. Should two menus ever list the same page, the later (its home menu) wins.
 */
export function activeNavItem(
  groups: readonly NavGroup[],
  pathname: string,
  kind?: string | null,
): { groupKey: string; href: string } | null {
  // Other receivables and payables share one form/detail path (`/assets/obligations/...`); the `kind` in the
  // address says which of the two menus (Piutang Lain / Utang Lain) the person came from.
  if (pathname === "/assets/obligations" || pathname.startsWith("/assets/obligations/")) {
    const target =
      kind === "receivable"
        ? "/assets/other-receivables"
        : kind === "payable"
          ? "/assets/other-payables"
          : null;
    if (target) {
      for (const group of groups) {
        if (group.items?.some((item) => item.href === target)) {
          return { groupKey: group.key, href: target };
        }
      }
    }
  }
  let best: { groupKey: string; href: string } | null = null;
  for (const group of groups) {
    for (const item of group.items ?? [{ label: group.label, href: group.href }]) {
      const matches =
        item.href === "/"
          ? pathname === "/"
          : pathname === item.href || pathname.startsWith(`${item.href}/`);
      if (matches && (!best || item.href.length >= best.href.length)) {
        best = { groupKey: group.key, href: item.href };
      }
    }
  }
  return best;
}
