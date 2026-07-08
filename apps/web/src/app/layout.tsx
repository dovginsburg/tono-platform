import type { Metadata, Viewport } from 'next';
import './globals.css';
import NavDropdown from './NavDropdown';
import TonoFooter from './TonoFooter';

export const metadata: Metadata = {
  title: 'tono — say what you mean',
  description: 'four ways to say it. pick one, copy, send.',
  applicationName: 'tono',
  appleWebApp: {
    capable: true,
    title: 'tono',
    statusBarStyle: 'black-translucent',
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  themeColor: '#000000',
  colorScheme: 'dark',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" data-theme="tono" className="dark">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        {children}
        {/* Site-wide footer + trust rail — present on every page.
            See TonoFooter.tsx for the spec. */}
        <TonoFooter />
        {/* Top-right nav dropdown — present on every page (nav-spec.md).
            Renders nothing until JS hydrates; client component. */}
        <NavDropdown />
      </body>
    </html>
  );
}