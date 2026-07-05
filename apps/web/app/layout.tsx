import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "tono — say what you mean. land how you intend.",
  description: "a pre-send communication coach: risk badge + 4 rewrites before you hit send.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
