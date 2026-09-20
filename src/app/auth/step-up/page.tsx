import { redirect } from "next/navigation";
import { CodeForm } from "@/features/auth/AuthForms";
import { logoutAction } from "@/features/auth/actions";
import { getAccessSnapshot } from "@/lib/auth/session";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/domain/authz/access";

export const metadata = { title: "Verifikasi ulang · Hikarich Finance" };

export default async function StepUpPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>;
}) {
  const { next } = await searchParams;
  const destination = safeNextPath(next, "/");

  const access = await getAccessSnapshot();
  if (!access) redirect(`/login?next=${encodeURIComponent(destination)}`);
  if (access.recent_step_up) redirect(destination);

  const supabase = await createSupabaseServerClient();
  const { data: factors } = await supabase.auth.mfa.listFactors();
  const hasVerifiedFactor = (factors?.totp?.length ?? 0) > 0;

  return (
    <main className="shell">
      <section className="card">
        <h1>Verifikasi ulang</h1>
        {hasVerifiedFactor ? (
          <>
            <p>Tindakan sensitif memerlukan kode autentikator terbaru (berlaku 10 menit).</p>
            <CodeForm next={destination} submitLabel="Lanjutkan" />
          </>
        ) : (
          <>
            <p>Tindakan sensitif memerlukan verifikasi ulang. Silakan keluar lalu masuk kembali.</p>
            <form action={logoutAction} className="form">
              <button type="submit">Keluar</button>
            </form>
          </>
        )}
      </section>
    </main>
  );
}
