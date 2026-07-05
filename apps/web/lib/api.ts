import { TonoApiClient } from "@tono/shared";

export const tonoApi = new TonoApiClient({
  baseUrl: process.env.NEXT_PUBLIC_TONO_API_URL ?? "http://localhost:8765",
});
