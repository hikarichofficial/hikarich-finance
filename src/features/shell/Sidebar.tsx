"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import type { NavGroup } from "@/domain/shell/navigation";
import { NavIcon } from "./icons";

/**
 * Primary navigation (Step 09 §2-§4). Pure presentation over the already-permission-filtered groups
 * `AppShell` hands down (`visibleNavigation`) -- this component never re-derives what is visible, it
 * only renders it and highlights the active link via the current path (Step 09 §4: "the active
 * destination is always visually distinct").
 */
export function Sidebar({
  groups,
  collapsed,
  onToggleCollapse,
  onNavigate,
}: {
  groups: readonly NavGroup[];
  collapsed: boolean;
  onToggleCollapse: () => void;
  onNavigate?: () => void;
}) {
  const pathname = usePathname();

  return (
    <aside className="app-sidebar">
      <div className="app-sidebar-brand">
        <Image src="/brand/hikarich-mark-512.png" alt="" width={32} height={32} />
        <span>Hikarich Finance</span>
      </div>
      <nav className="app-nav" aria-label="Navigasi utama">
        {groups.map((group) => (
          <div className="app-nav-group" key={group.key}>
            <div className="app-nav-group-title">{group.label}</div>
            {(group.items ?? [{ label: group.label, href: group.href }]).map((item) => {
              const active = pathname === item.href;
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className="app-nav-link"
                  aria-current={active ? "page" : undefined}
                  onClick={onNavigate}
                >
                  <NavIcon name={group.icon} />
                  <span className="app-nav-label">{item.label}</span>
                </Link>
              );
            })}
          </div>
        ))}
      </nav>
      <div className="app-sidebar-footer">
        <button
          type="button"
          className="app-sidebar-collapse-toggle"
          onClick={onToggleCollapse}
          aria-pressed={collapsed}
        >
          {collapsed ? (
            <PanelLeftOpen size={18} strokeWidth={1.75} aria-hidden="true" />
          ) : (
            <PanelLeftClose size={18} strokeWidth={1.75} aria-hidden="true" />
          )}
          <span className="app-nav-label">{collapsed ? "Perluas" : "Ciutkan"}</span>
        </button>
      </div>
    </aside>
  );
}
