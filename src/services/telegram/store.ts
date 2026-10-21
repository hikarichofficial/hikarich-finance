import "server-only";
import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { CategoryOption, LearnedRule } from "@/domain/telegram/categorize";
import { parseLang, type Lang } from "@/domain/telegram/i18n";
import type { SummaryData } from "@/domain/telegram/report";
import { StoreError } from "./errors";
import type {
  DraftState,
  EntityContext,
  LearnEntry,
  RecordPayload,
} from "@/domain/telegram/roadmap";

/**
 * The bot's only door to the database (decision 422): the `telegram_*` functions, callable by the service role alone.
 * Each one acts as the paired user and re-checks that user's permissions, so nothing here can do more than the owner
 * could do on the website. Errors carry the database's own code prefix (FORBIDDEN, INVALID, CONFLICT).
 */

export interface Membership {
  entityId: string;
  entityCode: string;
  entityType: string;
  entityName: string;
  canCreate: boolean;
  canConfirm: boolean;
  canView: boolean;
}

export interface Identity {
  linkId: string;
  userId: string;
  displayName: string;
  username: string | null;
  isPrivate: boolean;
  maxEntryAmount: number;
  /** What the bot says: Indonesian or English. */
  lang: Lang;
  reportDaily: boolean;
  reportWeekly: boolean;
  reportMonthly: boolean;
  chatEntityId: string | null;
  memberships: Membership[];
}

export interface DraftAsset {
  assetId: string;
  code: string;
  name: string;
  cost: number;
  entityType: "company" | "personal";
  canManage: boolean;
}

export interface OpenLoan {
  loanId: string;
  entityId: string;
  entityName: string;
  loanNumber: string;
  counterparty: string;
  seq: number;
  dueDate: string;
  amount: number;
  overdue: boolean;
  accounts: Array<{ id: string; name: string }>;
}

export interface FoundExpense {
  expenseId: string;
  entityId: string;
  entityName: string;
  entityType: "company" | "personal";
  number: string;
  status: string;
  date: string;
  total: number;
  currency: string;
  payee: string | null;
  canAttach: boolean;
}

export interface RecordResult {
  expenseId: string;
  status: string;
  number: string | null;
  total: number;
  reason: string | null;
  reasonCode: "ABOVE_LIMIT" | "FORBIDDEN" | "CONFLICT" | "INVALID" | "ERROR" | null;
}

export interface RecentEntry {
  expenseId: string;
  entityId: string;
  status: string;
  number: string | null;
  date: string;
  total: number;
  payee: string | null;
  lines: string | null;
}

export interface ReportTarget {
  linkId: string;
  chatId: number;
}

type Row = Record<string, unknown>;

async function rpc(
  client: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new StoreError(error.message);
  return data;
}

const str = (v: unknown): string => (typeof v === "string" ? v : "");
const strOrNull = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null);
const num = (v: unknown): number => {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
};
const rows = (v: unknown): Row[] => (Array.isArray(v) ? (v as Row[]) : []);

export function hashPairingCode(code: string): string {
  return createHash("sha256").update(code.trim().toUpperCase()).digest("hex");
}

export function createStore(client: SupabaseClient) {
  return {
    /** True the first time an update id is seen: Telegram retries must not be processed twice. */
    async claimUpdate(updateId: number): Promise<boolean> {
      return (await rpc(client, "telegram_claim_update", { p_update_id: updateId })) === true;
    },

    async redeemCode(code: string, telegramUser: number, chat: number, username: string | null) {
      const data = (await rpc(client, "telegram_redeem_code", {
        p_code_hash: hashPairingCode(code),
        p_telegram_user: telegramUser,
        p_chat: chat,
        p_username: username ?? "",
      })) as Row;
      return { linkId: str(data.link_id), displayName: str(data.display_name) };
    },

    /** Null for a stranger, an unregistered group or a disabled user: the bot stays silent. */
    async identify(telegramUser: number, chat: number, thread: number): Promise<Identity | null> {
      const data = (await rpc(client, "telegram_identify", {
        p_telegram_user: telegramUser,
        p_chat: chat,
        p_thread: thread,
      })) as Row | null;
      if (!data) return null;
      return {
        linkId: str(data.link_id),
        userId: str(data.user_id),
        displayName: str(data.display_name),
        username: strOrNull(data.username),
        isPrivate: data.is_private === true,
        maxEntryAmount: num(data.max_entry_amount),
        lang: parseLang(data.language),
        reportDaily: data.report_daily === true,
        reportWeekly: data.report_weekly === true,
        reportMonthly: data.report_monthly === true,
        chatEntityId: strOrNull(data.chat_entity_id),
        memberships: rows(data.memberships).map((m) => ({
          entityId: str(m.entity_id),
          entityCode: str(m.entity_code),
          entityType: str(m.entity_type),
          entityName: str(m.entity_name),
          canCreate: m.can_create === true,
          canConfirm: m.can_confirm === true,
          canView: m.can_view === true,
        })),
      };
    },

    /** Names only (categories, accounts, vendors, learned rules) for the Entities the user may record in. */
    async context(linkId: string): Promise<EntityContext[]> {
      const data = rows(await rpc(client, "telegram_context", { p_link: linkId }));
      return data.map((e) => ({
        entityId: str(e.entity_id),
        entityType: str(e.entity_type),
        entityName: str(e.entity_name),
        today: str(e.today),
        canConfirm: e.can_confirm === true,
        categories: rows(e.categories).map((c): CategoryOption => ({
          id: str(c.id),
          name: str(c.name),
          kind: c.kind === "asset" ? "asset" : "expense",
          isParent: c.is_parent === true,
        })),
        accounts: rows(e.accounts).map((a) => ({ id: str(a.id), name: str(a.name) })),
        vendors: rows(e.vendors).map((v) => ({ id: str(v.id), name: str(v.name) })),
        rules: rows(e.rules).map((r): LearnedRule => ({
          keyword: str(r.keyword),
          categoryId: strOrNull(r.category_id),
          accountId: strOrNull(r.account_id),
          payeeName: strOrNull(r.payee_name),
          hits: num(r.hits),
        })),
      }));
    },

    /**
     * Attaches the receipt photo to an entry this bot made: registers the file as a document (the website's own
     * rules: type, size, one document per content), stores the bytes once in the private bucket and links it as a
     * receipt. Returns false when the owner may not upload documents; the caller then just says so.
     */
    async attachReceipt(
      linkId: string,
      entityId: string,
      expenseId: string,
      file: { bytes: Uint8Array; mime: string },
    ): Promise<boolean> {
      const sha = createHash("sha256").update(file.bytes).digest("hex");
      const ext = file.mime === "image/png" ? "png" : file.mime === "image/webp" ? "webp" : "jpg";
      const registered = (await rpc(client, "telegram_register_receipt", {
        p_link: linkId,
        p_entity: entityId,
        p_key: `tg-doc-${sha.slice(0, 40)}`,
        p_file_name: `struk-telegram.${ext}`,
        p_mime: file.mime,
        p_size: file.bytes.byteLength,
        p_sha256: sha,
      })) as Row;
      const documentId = str(registered.document_id);
      const path = `${entityId}/${documentId}`;
      if (registered.stored !== true) {
        const { error } = await client.storage
          .from("documents")
          .upload(path, file.bytes, { contentType: file.mime, upsert: true });
        if (error) return false;
      }
      await rpc(client, "telegram_attach_receipt", {
        p_link: linkId,
        p_document: documentId,
        p_storage_path: path,
        p_expense: expenseId,
      });
      return true;
    },

    /** An entry on the website found by its transaction number, among the Entities the owner may view. */
    async findExpense(linkId: string, number: string): Promise<FoundExpense[]> {
      const data = await rpc(client, "telegram_find_expense", { p_link: linkId, p_number: number });
      return rows(data).map((x) => ({
        expenseId: str(x.expense_id),
        entityId: str(x.entity_id),
        entityName: str(x.entity_name),
        entityType: x.entity_type === "personal" ? "personal" : "company",
        number: str(x.number),
        status: str(x.status),
        date: str(x.date),
        total: num(x.total),
        currency: str(x.currency),
        payee: typeof x.payee === "string" ? x.payee : null,
        canAttach: x.can_attach === true,
      }));
    },

    /** Draft assets the website opened from the asset lines of an entry this bot made. */
    async expenseAssets(linkId: string, expenseId: string): Promise<DraftAsset[]> {
      const data = await rpc(client, "telegram_expense_assets", {
        p_link: linkId,
        p_expense: expenseId,
      });
      return rows(data).map((a) => ({
        assetId: str(a.asset_id),
        code: str(a.code),
        name: str(a.name),
        cost: num(a.cost),
        entityType: a.entity_type === "personal" ? "personal" : "company",
        canManage: a.can_manage === true,
      }));
    },

    /** Activates a draft asset: straight line over `lifeMonths` (a personal asset is kept at cost). */
    async activateAsset(
      linkId: string,
      key: string,
      assetId: string,
      lifeMonths: number | null,
    ): Promise<number> {
      return num(
        await rpc(client, "telegram_activate_asset", {
          p_link: linkId,
          p_key: key,
          p_asset: assetId,
          p_life_months: lifeMonths,
        }),
      );
    },

    /** Debts with their next unpaid instalment. */
    async openLoans(linkId: string): Promise<OpenLoan[]> {
      const data = await rpc(client, "telegram_loans_open", { p_link: linkId });
      return rows(data).map((l) => ({
        loanId: str(l.loan_id),
        entityId: str(l.entity_id),
        entityName: str(l.entity_name),
        loanNumber: str(l.loan_number),
        counterparty: str(l.counterparty),
        seq: num(l.seq),
        dueDate: str(l.due_date),
        amount: num(l.amount),
        overdue: l.overdue === true,
        accounts: rows(l.accounts).map((a) => ({ id: str(a.id), name: str(a.name) })),
      }));
    },

    /** Pays the next instalment exactly as the schedule says. */
    async payLoan(linkId: string, key: string, loanId: string, accountId: string): Promise<string> {
      return str(
        await rpc(client, "telegram_pay_loan", {
          p_link: linkId,
          p_key: key,
          p_loan: loanId,
          p_account: accountId,
        }),
      );
    },

    async recordExpense(
      linkId: string,
      payload: RecordPayload,
      confirm: boolean,
    ): Promise<RecordResult> {
      const data = (await rpc(client, "telegram_record_expense", {
        p_link: linkId,
        p_key: payload.key,
        p_entity: payload.entityId,
        p_account: payload.accountId,
        p_date: payload.date,
        p_lines: payload.lines,
        p_payee_id: null,
        p_payee_name: payload.payeeName,
        p_notes: null,
        p_confirm: confirm,
        p_replace: payload.replaces,
      })) as Row;
      const code = strOrNull(data.reason_code);
      return {
        expenseId: str(data.expense_id),
        status: str(data.status),
        number: strOrNull(data.number),
        total: num(data.total),
        reason: strOrNull(data.reason),
        reasonCode: (code as RecordResult["reasonCode"]) ?? null,
      };
    },

    async recentEntries(linkId: string, limit = 5): Promise<RecentEntry[]> {
      return rows(
        await rpc(client, "telegram_recent_entries", { p_link: linkId, p_limit: limit }),
      ).map((r) => ({
        expenseId: str(r.expense_id),
        entityId: str(r.entity_id),
        status: str(r.status),
        number: strOrNull(r.number),
        date: str(r.expense_date),
        total: num(r.total),
        payee: strOrNull(r.payee),
        lines: strOrNull(r.lines),
      }));
    },

    async undoEntry(linkId: string, key: string, expenseId: string): Promise<{ result: string }> {
      const data = (await rpc(client, "telegram_undo_entry", {
        p_link: linkId,
        p_key: key,
        p_expense: expenseId,
      })) as Row;
      return { result: str(data.result) };
    },

    async summary(
      linkId: string,
      entityId: string,
      from: string,
      to: string,
    ): Promise<SummaryData> {
      const d = (await rpc(client, "telegram_summary", {
        p_link: linkId,
        p_entity: entityId,
        p_from: from,
        p_to: to,
      })) as Row;
      return {
        entityName: str(d.entity_name),
        entityType: str(d.entity_type),
        from: str(d.from),
        to: str(d.to),
        total: num(d.total),
        count: num(d.count),
        byCategory: rows(d.by_category).map((c) => ({
          name: str(c.name),
          total: num(c.total),
          count: num(c.count),
        })),
        top: rows(d.top).map((t) => ({
          date: str(t.date),
          description: str(t.description),
          amount: num(t.amount),
          payee: strOrNull(t.payee),
        })),
        entries: rows(d.entries).map((e) => ({
          date: str(e.date),
          description: str(e.description),
          amount: num(e.amount),
          account: str(e.account),
        })),
        drafts: num(d.drafts),
        assetsToRegister: num(d.assets_to_register),
      };
    },

    async getSession(linkId: string, chat: number, thread: number): Promise<DraftState | null> {
      const data = (await rpc(client, "telegram_session_get", {
        p_link: linkId,
        p_chat: chat,
        p_thread: thread,
      })) as Row | null;
      if (!data || data.v !== 1) return null;
      return data as unknown as DraftState;
    },
    async putSession(
      linkId: string,
      chat: number,
      thread: number,
      state: DraftState,
    ): Promise<void> {
      await rpc(client, "telegram_session_put", {
        p_link: linkId,
        p_chat: chat,
        p_thread: thread,
        p_state: state,
        p_ttl_minutes: 120,
      });
    },
    async clearSession(linkId: string, chat: number, thread: number): Promise<void> {
      await rpc(client, "telegram_session_clear", {
        p_link: linkId,
        p_chat: chat,
        p_thread: thread,
      });
    },

    async learn(linkId: string, entry: LearnEntry): Promise<void> {
      await rpc(client, "telegram_learn", {
        p_link: linkId,
        p_entity: entry.entityId,
        p_keyword: entry.keyword,
        p_category: entry.categoryId,
        p_account: entry.accountId,
        p_payee: entry.payeeName,
      });
    },

    async setPrefs(
      linkId: string,
      prefs: { daily: boolean; weekly: boolean; monthly: boolean; defaultEntity: string | null },
    ): Promise<void> {
      await rpc(client, "telegram_set_prefs", {
        p_link: linkId,
        p_daily: prefs.daily,
        p_weekly: prefs.weekly,
        p_monthly: prefs.monthly,
        p_default_entity: prefs.defaultEntity,
      });
    },

    async registerChat(linkId: string, chat: number, kind: string, title: string): Promise<void> {
      await rpc(client, "telegram_register_chat", {
        p_link: linkId,
        p_chat: chat,
        p_kind: kind,
        p_title: title,
      });
    },
    async unregisterChat(linkId: string, chat: number): Promise<void> {
      await rpc(client, "telegram_unregister_chat", { p_link: linkId, p_chat: chat });
    },
    async setTopicEntity(
      linkId: string,
      chat: number,
      thread: number,
      entityId: string,
    ): Promise<void> {
      await rpc(client, "telegram_set_topic_entity", {
        p_link: linkId,
        p_chat: chat,
        p_thread: thread,
        p_entity: entityId,
      });
    },

    async reportTargets(kind: "daily" | "weekly" | "monthly"): Promise<ReportTarget[]> {
      return rows(await rpc(client, "telegram_report_targets", { p_kind: kind })).map((r) => ({
        linkId: str(r.link_id),
        chatId: Number(str(r.chat_id)),
      }));
    },

    async setLanguage(linkId: string, lang: Lang): Promise<void> {
      await rpc(client, "telegram_set_language", { p_link: linkId, p_language: lang });
    },

    async cleanup(): Promise<Row> {
      return (await rpc(client, "telegram_cleanup", {})) as Row;
    },
  };
}

export type TelegramStore = ReturnType<typeof createStore>;
