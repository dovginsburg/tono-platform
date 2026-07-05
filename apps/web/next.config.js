/** @type {import('next').NextConfig} */
const nextConfig = {
  // Resolve @tono/shared's TS source directly in dev; the workspace build
  // step (`npm run build:shared`) compiles it to dist/ for production.
  transpilePackages: ["@tono/shared"],
};

module.exports = nextConfig;
