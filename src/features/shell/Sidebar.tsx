"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { ChevronDown, PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { activeNavItem, type NavGroup } from "@/domain/shell/navigation";
import { NavIcon } from "./icons";

/**
 * Primary navigation (Step 09 §2-§4). Pure presentation over the already-permission-filtered groups
 * `AppShell` hands down (`visibleNavigation`) -- this component never re-derives what is visible, it
 * only renders it and highlights the active link via the current path (Step 09 §4: "the active
 * destination is always visually distinct").
 *
 * Decision 254 (OWNER): each menu is a row that reveals its submenu when pressed, so the sidebar stays
 * short. The menu holding the current page is open; pressing a menu opens it and closes the others the
 * person opened. In the collapsed (icon) sidebar a menu icon expands the sidebar and opens that menu.
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
  const active = activeNavItem(groups, pathname);
  // What the person toggled for the current page; navigating elsewhere falls back to the active menu.
  const [choice, setChoice] = useState<{ path: string; key: string | null } | null>(null);
  const openKey = choice && choice.path === pathname ? choice.key : (active?.groupKey ?? null);

  function toggle(key: string): void {
    if (collapsed) {
      onToggleCollapse();
      setChoice({ path: pathname, key });
      return;
    }
    setChoice({ path: pathname, key: openKey === key ? null : key });
  }

  return (
    <aside className="app-sidebar">
      <div className="app-sidebar-brand">
        <Image src="/brand/hikarich-mark-512.png" alt="" width={32} height={32} />
        <span>Hikarich Finance</span>
      </div>
      <nav className="app-nav" aria-label="Navigasi utama">
        {groups.map((group) => {
          const items = group.items ?? [{ label: group.label, href: group.href }];
          const open = !collapsed && openKey === group.key;
          const panelId = `nav-panel-${group.key}`;
          return (
            <div className="app-nav-group" key={group.key} data-open={open ? "true" : "false"}>
              <button
                type="button"
                className="app-nav-group-toggle"
                aria-expanded={open}
                aria-controls={panelId}
                data-active={active?.groupKey === group.key ? "true" : undefined}
                title={collapsed ? group.label : undefined}
                onClick={() => toggle(group.key)}
              >
                <NavIcon name={group.icon} />
                <span className="app-nav-label">{group.label}</span>
                <ChevronDown
                  className="app-nav-chevron"
                  size={16}
                  strokeWidth={1.75}
                  aria-hidden="true"
                />
              </button>
              <div className="app-nav-panel" id={panelId} hidden={!open}>
                {items.map((item) => {
                  const current = active?.groupKey === group.key && active.href === item.href;
                  return (
                    <Link
                      key={item.href}
                      href={item.href}
                      className="app-nav-link"
                      aria-current={current ? "page" : undefined}
                      onClick={onNavigate}
                    >
                      <span className="app-nav-label">{item.label}</span>
                    </Link>
                  );
                })}
              </div>
            </div>
          );
        })}
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
