"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import type { Role } from "./permissions";
import { friendlyError, isConfigured, supabase } from "./supabase";

/**
 * Who is signed in.
 *
 * Connected copy: real Supabase sign-in; the role comes from the employees table and the
 * database enforces it (row level security). This gate only decides which screen to show.
 *
 * Copy with no database configured: a clearly labelled DESIGN PREVIEW where the reviewer
 * picks a role. It holds no people or records.
 */
export interface Session {
  employeeId: string | null;
  name: string;
  email: string;
  role: Role;
  preview: boolean;
  setPreviewRole: (r: Role) => void;
  signOut: () => Promise<void>;
}

interface EmployeeRow {
  id: string;
  full_name: string;
  email: string;
  role: Role;
  active: boolean;
}

const KEY = "attendos.previewRole";
const Ctx = createContext<Session | null>(null);

export function useSession(): Session {
  const s = useContext(Ctx);
  if (!s) throw new Error("useSession must be used inside SessionProvider");
  return s;
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

async function loadEmployee(id: string): Promise<EmployeeRow | null> {
  const { data, error } = await supabase().from("employees").select("id, full_name, email, role, active").eq("id", id).maybeSingle<EmployeeRow>();
  if (error) throw error;
  return data;
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
    <Ctx.Provider value={{ employeeId: null, name: "Preview user", email: "preview@attendos.local", role, preview: true, setPreviewRole, signOut: async () => {} }}>
      {children}
    </Ctx.Provider>
  );
}

function LiveProvider({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const path = usePathname();
  const [me, setMe] = useState<EmployeeRow | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    const sb = supabase();
    async function check(userId: string | null) {
      if (!userId) return router.replace("/login");
      try {
        const row = await loadEmployee(userId);
        if (!live) return;
        if (!row || !row.active) return signOut("inactive");
        setMe(row);
        setProblem(null);
      } catch (e) {
        if (live) setProblem(friendlyError(e));
      }
    }
    sb.auth.getSession().then(({ data }) => check(data.session?.user.id ?? null));
    const { data: sub } = sb.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT" && !signingOutHere) window.location.replace("/login?error=signed-out");
    });
    return () => {
      live = false;
      sub.subscription.unsubscribe();
    };
  }, [router]);

  // Re-check on every screen change and when the tab returns, so a deactivated login ends quickly.
  const id = me?.id;
  useEffect(() => {
    if (!id) return;
    const recheck = () =>
      loadEmployee(id)
        .then((row) => {
          if (!row || !row.active) return signOut("inactive");
          setMe((cur) => (cur && (cur.role !== row.role || cur.full_name !== row.full_name) ? row : cur));
        })
        .catch(() => {
          /* offline: screens show their own message */
        });
    recheck();
    const onVis = () => document.visibilityState === "visible" && recheck();
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, [id, path]);

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
    <Ctx.Provider value={{ employeeId: me.id, name: me.full_name, email: me.email, role: me.role, preview: false, setPreviewRole: () => {}, signOut: () => signOut() }}>
      {children}
    </Ctx.Provider>
  );
}

export function SessionProvider({ children }: { children: React.ReactNode }) {
  return isConfigured() ? <LiveProvider>{children}</LiveProvider> : <PreviewProvider>{children}</PreviewProvider>;
}
