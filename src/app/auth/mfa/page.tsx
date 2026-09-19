import { redirect } from "next/navigation";
import { CodeForm, EnrollForm } from "@/features/auth/AuthForms";
import { getAccessSnapshot } from "@/lib/auth/session";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { membershipsNeedingMfa, safeNextPath } from "@/domain/authz/access";

export const metadata = { title: "Verifikasi dua langkah · Hikarich Finance" };

export default async function MfaPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>;
}) {
  const { next } = await searchParams;
  const destination = safeNextPath(next, "/");

  const access = await getAccessSnapshot();
  if (!access) redirect(`/login?next=${encodeURIComponent(destination)}`);
  if (membershipsNeedingMfa(access).length === 0) redirect(destination);

  const supabase = await createSupabaseServerClient();
  const { data: factors } = await supabase.auth.mfa.listFactors();
  const hasVerifiedFactor = (factors?.totp?.length ?? 0) > 0;

  return (
    <main className="shell">
      <section className="card">
        <h1>Verifikasi dua langkah</h1>
        {hasVerifiedFactor ? (
          <>
            <p>Masukkan kode dari aplikasi autentikator Anda.</p>
            <CodeForm next={destination} submitLabel="Verifikasi" />
          </>
        ) : (
          <EnrollForm next={destination} />
        )}
      </section>
    </main>
  );
}
