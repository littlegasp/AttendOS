"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import type { Role } from "./permissions";

/**
 * Who is signed in.
 *
 * Phase 1 has no database yet, so the app runs as a clearly labelled DESIGN PREVIEW:
 * the reviewer picks a role to see how the shell adapts. No real people or records exist.
 * Phase 2 replaces `preview` with real sign-in (Supabase, as in studio-crm), and the role
 * then comes from the server, never from this switch.
 */
export interface Session {
  name: string;
  email: string;
  role: Role;
  preview: boolean;
  setPreviewRole: (r: Role) => void;
}

const KEY = "attendos.previewRole";
const Ctx = createContext<Session | null>(null);

export function SessionProvider({ children }: { children: React.ReactNode }) {
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
    <Ctx.Provider value={{ name: "Preview user", email: "preview@attendos.local", role, preview: true, setPreviewRole }}>
      {children}
    </Ctx.Provider>
  );
}

export function useSession(): Session {
  const s = useContext(Ctx);
  if (!s) throw new Error("useSession must be used inside SessionProvider");
  return s;
}
