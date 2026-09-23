import {
  LayoutDashboard,
  ShoppingCart,
  Receipt,
  Wallet,
  BookOpen,
  Landmark,
  Building2,
  Users,
  Target,
  BarChart3,
  FolderOpen,
  Settings,
  type LucideIcon,
} from "lucide-react";
import type { NavIconName } from "@/domain/shell/navigation";

/** Maps the pure `NavIconName` data key to its Lucide component. The only place in P13 Part 1 that
 * imports an icon library, so a future swap touches one file. */
const ICONS: Record<NavIconName, LucideIcon> = {
  LayoutDashboard,
  ShoppingCart,
  Receipt,
  Wallet,
  BookOpen,
  Landmark,
  Building2,
  Users,
  Target,
  BarChart3,
  FolderOpen,
  Settings,
};

export function NavIcon({ name, size = 18 }: { name: NavIconName; size?: number }) {
  const Icon = ICONS[name];
  return <Icon size={size} strokeWidth={1.75} aria-hidden="true" />;
}
