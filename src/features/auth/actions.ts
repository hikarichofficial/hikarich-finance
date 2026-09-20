"use server";

import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { loginInputSchema, otpCodeSchema } from "@/schemas/access";
import { safeNextPath } from "@/domain/authz/access";

export interface FormState {
  error?: string;
}

const GENERIC_LOGIN_ERROR = "Email atau kata sandi tidak sesuai.";
const GENERIC_CODE_ERROR = "Kode tidak sesuai atau sudah kedaluwarsa.";

function nextFrom(formData: FormData): string {
  return safeNextPath(formData.get("next"), "/");
}

/** Password sign-in (Step 06: Supabase Auth). Never reveals whether the email exists. */
export async function loginAction(_prev: FormState, formData: FormData): Promise<FormState> {
  const parsed = loginInputSchema.safeParse({
    email: formData.get("email"),
    password: formData.get("password"),
  });
  if (!parsed.success) return { error: GENERIC_LOGIN_ERROR };

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  if (error) return { error: GENERIC_LOGIN_ERROR };

  const next = nextFrom(formData);
  const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  // MFA is mandatory for OWNER and any role whose Entity requires it. `requireAccess` decides per
  // membership; here we only route people who already have (or must create) a second factor.
  if (aal?.nextLevel === "aal2" && aal.currentLevel !== "aal2") {
    redirect(`/auth/mfa?next=${encodeURIComponent(next)}`);
  }
  redirect(next);
}

export async function logoutAction(): Promise<void> {
  const supabase = await createSupabaseServerClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export interface EnrollmentStart {
  error?: string;
  factorId?: string;
  qrCode?: string;
  secret?: string;
}

/** Starts TOTP enrollment for the signed-in person; stale unverified factors are removed first. */
export async function startTotpEnrollment(): Promise<EnrollmentStart> {
  const supabase = await createSupabaseServerClient();
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims?.sub) return { error: "Sesi tidak valid. Silakan masuk kembali." };

  const { data: factors } = await supabase.auth.mfa.listFactors();
  for (const factor of factors?.all ?? []) {
    if (factor.status === "unverified") await supabase.auth.mfa.unenroll({ factorId: factor.id });
  }
  const { data, error } = await supabase.auth.mfa.enroll({
    factorType: "totp",
    friendlyName: `Hikarich ${new Date().toISOString().slice(0, 19)}`,
  });
  if (error || !data) return { error: "Gagal memulai pengaturan autentikator." };
  return { factorId: data.id, qrCode: data.totp.qr_code, secret: data.totp.secret };
}

/** Confirms a freshly enrolled factor; on success the session is upgraded to aal2. */
export async function verifyTotpEnrollment(
  _prev: FormState,
  formData: FormData,
): Promise<FormState> {
  const code = otpCodeSchema.safeParse(formData.get("code"));
  const factorId = String(formData.get("factorId") ?? "");
  if (!code.success || !factorId) return { error: GENERIC_CODE_ERROR };

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: code.data });
  if (error) return { error: GENERIC_CODE_ERROR };
  redirect(nextFrom(formData));
}

/** Second-factor challenge at sign-in (aal1 -> aal2) and step-up re-verification share this action. */
export async function verifyTotpAction(_prev: FormState, formData: FormData): Promise<FormState> {
  const code = otpCodeSchema.safeParse(formData.get("code"));
  if (!code.success) return { error: GENERIC_CODE_ERROR };

  const supabase = await createSupabaseServerClient();
  const { data: factors } = await supabase.auth.mfa.listFactors();
  const totp = factors?.totp?.[0];
  if (!totp) return { error: GENERIC_CODE_ERROR };

  const { error } = await supabase.auth.mfa.challengeAndVerify({
    factorId: totp.id,
    code: code.data,
  });
  if (error) return { error: GENERIC_CODE_ERROR };
  redirect(nextFrom(formData));
}
