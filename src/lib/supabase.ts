import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/**
 * The one database connection, running in the browser as the signed-in person, so row
 * level security decides what they can see and do (same set-up as studio-crm).
 * Returns null when this copy has no database configured yet (design preview).
 */
let client: SupabaseClient | null = null;

export function isConfigured(): boolean {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY);
}

export function supabase(): SupabaseClient {
  if (client) return client;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) throw new Error("This copy is not connected to a database yet.");
  client = createClient(url.replace(/\/(rest|auth)\/v1\/?$/, "").replace(/\/$/, ""), key, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storageKey: "attendos-auth" },
  });
  return client;
}

/** Plain-language message for anything that went wrong talking to the database. */
export function friendlyError(e: unknown): string {
  const msg = e instanceof Error ? e.message : typeof e === "object" && e && "message" in e ? String((e as { message: unknown }).message) : String(e);
  if (/fetch|network|Failed to fetch|NetworkError|Load failed/i.test(msg)) return "Couldn't reach the server. Check your internet connection and try again.";
  if (/JWT|expired|not authenticated/i.test(msg)) return "Your sign-in has expired. Sign in again.";
  if (/permission|row-level security|policy/i.test(msg)) return "You don't have permission to do that.";
  return msg || "Something went wrong. Try again.";
}
