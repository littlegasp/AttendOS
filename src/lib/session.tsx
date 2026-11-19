"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { BRAND, brandCss } from "./brand";
import type { Role } from "./permissions";
import { friendlyError, isConfigured, supabase } from "./supabase";

/**
 * Who is signed in, and which company they belong to.
 *
 * Connected copy: real Supabase sign-in. The login is linked to an employee record (by
 * confirmed e-mail); that record gives the company, role and time zone, and the database
 * enforces all of it (row level security). This gate only decides which screen to show.
 *
 * Copy with no database configured: a clearly labelled DESIGN PREVIEW where the reviewer
 * picks a role. It holds no people or records.
 */
export interface Company {
  id: string;
  name: string;
  slug: string;
  timezone: string;
  app_name: string | null;
  logo_url: string | null;
  accent_dark: string | null;
  accent_light: string | null;
  date_format?: string;
}

export interface Session {
  employeeId: string | null;
  companyId: string | null;
  company: Company | null;
  name: string;
  email: string;
  role: Role;
  preview: boolean;
  setPreviewRole: (r: Role) => void;
  signOut: () => Promise<void>;
  /** Re-read the company after an Admin changes its settings (time zone, branding). */
  refreshCompany: () => void;
}

interface EmployeeRow {
  id: string;
  full_name: string;
  email: string;
  role: Role;
  active: boolean;
  company_id: string;
  company: Company | null;
}

const KEY = "attendos.previewRole";
const Ctx = createContext<Session | null>(null);

export function useSession(): Session {
  const s = useContext(Ctx);
  if (!s) throw new Error("useSession must be used inside SessionProvider");
  return s;
}

/** Name, tagline and logo to show: the company's own branding when set, else the product's. */
export function useBrand() {
  const s = useContext(Ctx);
  const c = s?.company;
  return {
    appName: c?.app_name || (c ? c.name : BRAND.appName),
    tagline: c?.app_name ? c.name : c ? BRAND.tagline : BRAND.tagline,
    logo: c?.logo_url || BRAND.logo,
  };
}

let signingOutHere = false;

export async function signOut(reason?: string) {
  signingOutHere = true;
  try {
    await supabase().auth.signOut({ scope: "local" });
  } catch {
    /* already signed out */
  }
  window.location.replace(reason ? `/login?error=${reason}` : "/login");
}

const COLS = "id, full_name, email, role, active, company_id, company:companies(id, name, slug, timezone, app_name, logo_url, accent_dark, accent_light, date_format)";

async function loadEmployee(userId: string): Promise<EmployeeRow | null> {
  const { data, error } = await supabase().from("employees").select(COLS).eq("user_id", userId).maybeSingle<EmployeeRow>();
  if (error) throw error;
  return data;
}

/** The database's answer for a login that can't see its own record: switched off, or never linked. */
async function whyNoAccess(): Promise<string> {
  const { data } = await supabase().rpc("my_account_status");
  return data === "inactive" ? "inactive" : "not-linked";
}

function PreviewProvider({ children }: { children: React.ReactNode }) {
  const [role, setRole] = useState<Role>("admin");
  useEffect(() => {
    try {
      const saved = localStorage.getItem(KEY);
      if (saved === "admin" || saved === "hr" || saved === "manager" || saved === "employee") setRole(saved);
    } catch {
      /* storage blocked: preview starts as Admin */
    }
  }, []);
  const setPreviewRole = useCallback((r: Role) => {
    setRole(r);
    try {
      localStorage.setItem(KEY, r);
    } catch {
      /* not remembered */
    }
  }, []);
  return (
    <Ctx.Provider
      value={{ employeeId: null, companyId: null, company: null, name: "Preview user", email: "preview@attendos.local", role, preview: true, setPreviewRole, signOut: async () => {}, refreshCompany: () => {} }}
    >
      {children}
    </Ctx.Provider>
  );
}

/** Applies the company's accent colour over the default tokens (validated in brandCss). */
function CompanyAccent({ c }: { c: Company | null }) {
  if (!c?.accent_dark || !c.accent_light) return null;
  const css = brandCss({ ...BRAND, accent: { dark: c.accent_dark, light: c.accent_light, darkSoft: c.accent_dark, lightSoft: c.accent_light } });
  return css ? <style dangerouslySetInnerHTML={{ __html: css }} /> : null;
}

function LiveProvider({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const path = usePathname();
  const [me, setMe] = useState<EmployeeRow | null>(null);
  const [userId, setUserId] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let live = true;
    const sb = supabase();
    async function check(uid: string | null) {
      if (!uid) return router.replace("/login");
      try {
        const row = await loadEmployee(uid);
        if (!live) return;
        // No employee record linked to this login, or the record is switched off / past the last day.
        if (!row || !row.active) return signOut(await whyNoAccess());
        setUserId(uid);
        setMe(row);
        setProblem(null);
      } catch (e) {
        if (live) setProblem(friendlyError(e));
      }
    }
    sb.auth.getSession().then(({ data }) => check(data.session?.user.id ?? null));
    const { data: sub } = sb.auth.onAuthStateChange((event) => {
      // Signed out elsewhere, or the session could not be refreshed (expired / revoked): back to sign-in.
      if (event === "SIGNED_OUT" && !signingOutHere) window.location.replace("/login?error=signed-out");
    });
    return () => {
      live = false;
      sub.subscription.unsubscribe();
    };
  }, [router]);

  // Re-check on every screen change, when the tab returns, and after company settings change,
  // so a deactivated login ends quickly and a new time zone applies at once.
  useEffect(() => {
    if (!userId) return;
    const recheck = () =>
      loadEmployee(userId)
        .then(async (row) => {
          if (!row || !row.active) return signOut(await whyNoAccess());
          setMe((cur) => (cur && JSON.stringify(cur) !== JSON.stringify(row) ? row : cur));
        })
        .catch(() => {
          /* offline: screens show their own message */
        });
    recheck();
    const onVis = () => document.visibilityState === "visible" && recheck();
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, [userId, path, tick]);

  if (problem) {
    return (
      <div className="center-screen">
        <div className="card glass auth-card" role="alert">
          <p>{problem}</p>
          <button type="button" className="btn primary md" onClick={() => window.location.reload()}>Try again</button>
        </div>
      </div>
    );
  }
  if (!me) return <div className="center-screen" aria-busy="true"><span className="spinner" /><span className="sr-only">Loading…</span></div>;

  return (
    <Ctx.Provider
      value={{
        employeeId: me.id,
        companyId: me.company_id,
        company: me.company,
        name: me.full_name,
        email: me.email,
        role: me.role,
        preview: false,
        setPreviewRole: () => {},
        signOut: () => signOut(),
        refreshCompany: () => setTick((t) => t + 1),
      }}
    >
      <CompanyAccent c={me.company} />
      {children}
    </Ctx.Provider>
  );
}

export function SessionProvider({ children }: { children: React.ReactNode }) {
  return isConfigured() ? <LiveProvider>{children}</LiveProvider> : <PreviewProvider>{children}</PreviewProvider>;
}
