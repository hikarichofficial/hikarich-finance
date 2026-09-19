import Image from "next/image";

// P0 minimal shell only. No business UI, and no financial data, exists yet.
export default function Home() {
  return (
    <main className="shell">
      <section className="card">
        <Image
          className="mark"
          src="/brand/hikarich-mark-512.png"
          alt="Logo Hikarich"
          width={96}
          height={96}
          priority
        />
        <h1>Hikarich Finance</h1>
        <p>Fondasi proyek siap. Modul keuangan dibangun bertahap sesuai fase P0–P15.</p>
        <span className="badge">P0 · Project Bootstrap</span>
      </section>
    </main>
  );
}
