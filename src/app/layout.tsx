import type { Metadata } from "next";
import "./globals.css";
import { FeedbackProvider } from "@/features/feedback/FeedbackProvider";

export const metadata: Metadata = {
  title: "Hikarich Finance",
  description: "Sistem keuangan PT Hikarich Kitana Digital dan Personal Entity.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="id">
      <body>
        <FeedbackProvider>{children}</FeedbackProvider>
      </body>
    </html>
  );
}
