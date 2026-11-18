import type { NextConfig } from "next";

/**
 * Same set-up as studio-crm: the app is built into plain static files that Cloudflare
 * serves. Pages are drawn in the browser. Attendance checks that must be trusted
 * (geofence, server time, duplicates) will run in the database layer from Phase 2,
 * never in the browser.
 */
const nextConfig: NextConfig = {
  output: "export",
  images: { unoptimized: true },
  trailingSlash: false,
};

export default nextConfig;
