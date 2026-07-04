import type { Config } from 'tailwindcss';

// Mirrors /Users/Ezra/Projects/team/mark-deliverables/design-tokens.json
// (products.tono + components.* + global.*). Two-product token tree;
// Tono takes the dark/operate branch, ParentScript takes the light/clinical
// branch — this app only consumes the tono branch.
const config: Config = {
  content: ['./src/**/*.{ts,tsx,mdx}'],
  theme: {
    extend: {
      colors: {
        tono: {
          bg: '#000000',
          'bg-soft': '#0A0A0A',
          'bg-card': '#111113',
          'bg-elev': '#16161A',
          border: '#1F1F23',
          'border-strong': '#2A2A30',
          text: '#FFFFFF',
          'text-soft': '#C9C9D1',
          'text-softer': '#9CA3AF',
          muted: '#6B7280',
          accent: '#A855F7',
          'accent-hover': '#9333EA',
          'accent-soft': 'rgba(168,85,247,0.12)',
          'accent-softer': 'rgba(168,85,247,0.06)',
          'accent-light': '#D8B4FE',
          'accent-glow': 'rgba(168,85,247,0.35)',
        },
        'tone-warmer': '#F472B6',
        'tone-clearer': '#38BDF8',
        'tone-funnier': '#FBBF24',
        'tone-safer': '#34D399',
      },
      fontFamily: {
        sans: [
          'Inter',
          '-apple-system',
          'BlinkMacSystemFont',
          'Segoe UI',
          'Roboto',
          'Helvetica',
          'Arial',
          'sans-serif',
        ],
        mono: [
          'JetBrains Mono',
          'ui-monospace',
          'SFMono-Regular',
          'Menlo',
          'Monaco',
          'Consolas',
          'monospace',
        ],
      },
      borderRadius: {
        sm: '8px',
        md: '12px',
        lg: '18px',
        xl: '24px',
        '2xl': '32px',
      },
      boxShadow: {
        xs: '0 1px 2px rgba(0,0,0,0.04)',
        sm: '0 2px 8px rgba(0,0,0,0.06)',
        md: '0 8px 24px rgba(0,0,0,0.08)',
        lg: '0 24px 64px rgba(0,0,0,0.12)',
        'focus-tono': '0 0 0 3px rgba(168,85,247,0.35)',
      },
      transitionTimingFunction: {
        'tono-standard': 'cubic-bezier(0.2, 0.8, 0.2, 1)',
      },
    },
  },
  plugins: [],
};

export default config;