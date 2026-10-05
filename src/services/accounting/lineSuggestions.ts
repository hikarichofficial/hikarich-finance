import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { uuidResultSchema } from "@/schemas/accounting";
import {
  dedupeSuggestions,
  normalizeDescription,
  type LineSuggestion,
} from "@/domain/sales/lineSuggestions";

type LineKind = "invoice" | "bill" | "expense";

const LINE_TABLE: Record<LineKind, string> = {
  invoice: "invoice_lines",
  bill: "bill_lines",
  expense: "expense_lines",
};

interface LineRow {
  description: string;
  unit_price: string | number;
  category_id: string | null;
}

/**
 * Descriptions already used on earlier lines of this Entity (newest first, one per name) plus, for an invoice,
 * the products on file with their default price, for the suggestion popup above a line's description field
 * (OWNER, 5 October 2026). Direct RLS-scoped reads -- the same `invoices.view` / `bills.view` that already
 * let the person open those documents -- and best effort: a failed read returns an empty list, because a
 * missing convenience must never stop a form from opening.
 */
export async function listLineSuggestions(
  entityId: string,
  kind: LineKind,
): Promise<LineSuggestion[]> {
  try {
    const entity = uuidResultSchema.parse(entityId);
    const supabase = await createSupabaseServerClient();
    const { data } = await supabase
      .from(LINE_TABLE[kind])
      .select("description, unit_price, category_id")
      .eq("entity_id", entity)
      .order("created_at", { ascending: false })
      .limit(600);
    const history: LineSuggestion[] = ((data ?? []) as LineRow[]).map((row) => ({
      description: row.description,
      unit_price: String(row.unit_price),
      category_id: row.category_id,
    }));
    let products: LineSuggestion[] = [];
    if (kind === "invoice") {
      const { data: productData } = await supabase
        .from("products")
        .select("name, default_unit_price, default_category_id")
        .eq("entity_id", entity)
        .eq("is_active", true)
        .order("name");
      products = (
        (productData ?? []) as {
          name: string;
          default_unit_price: string | number | null;
          default_category_id: string | null;
        }[]
      ).map((product) => ({
        description: product.name,
        unit_price: product.default_unit_price === null ? "" : String(product.default_unit_price),
        category_id: product.default_category_id,
      }));
    }
    const deduped = dedupeSuggestions([...history, ...products]);
    // A product's own default category/price only fills a gap: a product that has never been invoiced shows
    // up as it is, one that has keeps the price it was last sold at (history comes first).
    return deduped.filter((item) => normalizeDescription(item.description) !== "");
  } catch {
    return [];
  }
}
