"use server";

import { headers } from "next/headers";
import { firstForwardedAddress, hashRequester } from "@/domain/sales/requester";
import { parseMoneyInput } from "@/domain/money/input";
import { submitPublicClaim } from "@/services/sales/public";

export type ClaimStatus =
  "idle" | "received" | "already_received" | "unavailable" | "throttled" | "conflict" | "invalid";

export interface ClaimState {
  status: ClaimStatus;
}

/** Used when no PUBLIC_CLAIM_SALT is configured (Preview, development); Production sets a secret value. */
const FALLBACK_SALT = "hikarich-public-claim-fallback-salt";

function text(formData: FormData, name: string): string | undefined {
  const value = formData.get(name);
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

/**
 * "Saya Sudah Bayar" on the customer's invoice page. It records a PENDING claim only; nothing about cash or
 * the ledger changes until a person with authority confirms it after checking the money really arrived.
 */
export async function submitClaimAction(
  _previous: ClaimState,
  formData: FormData,
): Promise<ClaimState> {
  const amount = parseMoneyInput(text(formData, "amount") ?? "");
  const token = text(formData, "token") ?? "";
  if (amount === null) return { status: "invalid" };

  const requestHeaders = await headers();
  const address =
    firstForwardedAddress(requestHeaders.get("x-forwarded-for")) ||
    requestHeaders.get("x-real-ip") ||
    "";
  const salt = process.env.PUBLIC_CLAIM_SALT?.trim() || FALLBACK_SALT;
  const requester = hashRequester(salt, address, requestHeaders.get("user-agent") ?? "");

  const outcome = await submitPublicClaim(
    {
      token,
      amount,
      payment_date: text(formData, "payment_date") ?? "",
      payer_name: text(formData, "payer_name"),
      reference: text(formData, "reference"),
      note: text(formData, "note"),
    },
    requester,
  );
  if (outcome.state === "received") {
    return { status: outcome.alreadyReceived ? "already_received" : "received" };
  }
  return { status: outcome.state };
}
