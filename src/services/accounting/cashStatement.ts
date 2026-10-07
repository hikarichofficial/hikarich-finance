import "server-only";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import {
  cashAccountOptionSchema,
  cashStatementSchema,
  type CashAccountOption,
  type CashStatement,
} from "@/schemas/cashStatement";
import { z } from "zod";

/** One page of the monthly cash/bank statement (decision 326). `financialAccountId` null = all accounts. */
export async function getCashStatement(input: {
  entityId: string;
  financialAccountId: string | null;
  month: string | null;
  limit: number;
  offset: number;
}): Promise<CashStatement> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("cash_statement", {
    p_entity: z.uuid().parse(input.entityId),
    p_financial_account: input.financialAccountId,
    p_month: input.month,
    p_limit: input.limit,
    p_offset: input.offset,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Rekening koran tidak dapat dimuat.");
  }
  const parsed = cashStatementSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons rekening koran tidak dikenali.");
  return parsed.data;
}

/** The cash and bank accounts to pick from (an RLS-governed read; best effort, empty when not readable). */
export async function listCashAccountOptions(entityId: string): Promise<CashAccountOption[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("financial_accounts")
    .select("id, name")
    .eq("entity_id", z.uuid().parse(entityId))
    .order("name");
  if (error || !data) return [];
  const parsed = z.array(cashAccountOptionSchema).safeParse(data);
  return parsed.success ? parsed.data : [];
}
