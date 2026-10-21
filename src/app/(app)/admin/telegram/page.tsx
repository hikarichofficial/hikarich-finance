import { requirePermission } from "@/services/identity/access";
import { getMyTelegramLink } from "@/services/telegram/link";
import { loadBotStatus } from "@/services/telegram/status";
import { TelegramScreen } from "@/features/telegram/TelegramScreen";

/**
 * Telegram bot settings (decision 422), gated on `bills.create`: the permission to record the expenses the bot records.
 * The pairing code, the limit and the reports are database functions under the person's own session; this page only
 * shows them. Registering the webhook is a separate system-wide action gated on `backup.create` (OWNER).
 */
export default async function TelegramPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  await requirePermission("bills.create", { entityCode: entity });
  const [link, status] = await Promise.all([getMyTelegramLink(), loadBotStatus()]);
  return <TelegramScreen status={status} link={link} />;
}
