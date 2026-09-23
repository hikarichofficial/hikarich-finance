"use client";

import { Bell, LogOut, Menu, Search } from "lucide-react";
import { logoutAction } from "@/features/auth/actions";
import type { Membership } from "@/schemas/access";
import { EntitySwitcher } from "./EntitySwitcher";

export function TopBar({
  displayName,
  membership,
  switchable,
  onOpenMobileMenu,
  onOpenCommandMenu,
}: {
  displayName: string | null;
  membership: Membership;
  switchable: readonly Membership[];
  onOpenMobileMenu: () => void;
  onOpenCommandMenu: () => void;
}) {
  return (
    <header className="app-topbar">
      <button
        type="button"
        className="icon-button app-topbar-menu-button"
        onClick={onOpenMobileMenu}
        aria-label="Buka menu navigasi"
      >
        <Menu size={20} strokeWidth={1.75} aria-hidden="true" />
      </button>
      <EntitySwitcher current={membership} switchable={switchable} />
      <button type="button" className="app-topbar-search" onClick={onOpenCommandMenu}>
        <Search size={16} strokeWidth={1.75} aria-hidden="true" />
        <span>Cari atau buka halaman...</span>
        <kbd>⌘K</kbd>
      </button>
      <div className="app-topbar-actions">
        <button type="button" className="icon-button" aria-label="Notifikasi">
          <Bell size={18} strokeWidth={1.75} aria-hidden="true" />
        </button>
        <form action={logoutAction}>
          <button
            type="submit"
            className="icon-button"
            aria-label={`Keluar (${displayName ?? "Pengguna"})`}
            title={displayName ?? undefined}
          >
            <LogOut size={18} strokeWidth={1.75} aria-hidden="true" />
          </button>
        </form>
      </div>
    </header>
  );
}
