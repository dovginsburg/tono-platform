/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // API rewrites so the browser doesn't need to know about the backend
  async rewrites() {
    return [
      { source: '/api/tono/:path*', destination: 'https://api.tonoit.com/v1/:path*' },
      { source: '/api/health', destination: 'https://api.tonoit.com/health' },
    ];
  },
};
module.exports = nextConfig;
