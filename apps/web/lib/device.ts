"use client";

import { tonoApi } from "@/lib/api";

const STORAGE_KEY = "tono_device_token";

/**
 * Every backend call that needs a bearer token (passkeys, Apple/Google
 * sign-in, the rate-limited /api/analyze) needs a registered device first.
 * This bootstraps one transparently on first use and caches it in
 * localStorage — the web equivalent of what the iOS/Android apps do on
 * first launch.
 */
export async function ensureDeviceToken(): Promise<string> {
  const existing = window.localStorage.getItem(STORAGE_KEY);
  if (existing) return existing;

  const reg = await tonoApi.register({ platform: "web" });
  window.localStorage.setItem(STORAGE_KEY, reg.api_token);
  return reg.api_token;
}
