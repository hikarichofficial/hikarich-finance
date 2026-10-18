import type { Metadata, Viewport } from "next";
import "./globals.css";
import { FeedbackProvider } from "@/features/feedback/FeedbackProvider";

export const metadata: Metadata = {
  title: "Hikarich Finance",
  description: "Sistem keuangan PT Hikarich Kitana Digital dan Personal Entity.",
  robots: { index: false, follow: false },
  // iPhone/iPad "Add to Home Screen": opens full screen under this short name (decision 421).
  appleWebApp: { capable: true, title: "Hikarich", statusBarStyle: "default" },
  // Phone numbers and dates in the screens are not links: stop iOS from turning them into ones.
  formatDetection: { telephone: false, email: false, address: false },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  // The browser bar on Android takes the colour of the page.
  themeColor: "#f7f2ec",
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
