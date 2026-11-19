"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { BrandMark } from "@/components/AppSidebar";
import { Button, FormInput } from "@/components/ui";
import { BRAND } from "@/lib/brand";
import { friendlyError, isConfigured, supabase } from "@/lib/supabase";

/** Opened from the reset email: the link signs the person in, then they choose a new password. */
export default function ResetPasswordPage() {
  const router = useRouter();
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isConfigured()) return setError("This copy isn't connected to a database yet.");
    const expired = "This reset link has expired or was already used. Ask for a new one from the sign-in page.";
    const hash = new URLSearchParams(window.location.hash.slice(1));
    if (hash.get("error_code") || hash.get("error")) return setError(expired);
    const sb = supabase();
    sb.auth.getSession().then(({ data }) => (data.session ? setReady(true) : setError(expired)));
  }, []);

  async function save(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const pw = String(fd.get("password") ?? "");
    const again = String(fd.get("again") ?? "");
    if (pw.length < 8) return setError("Use at least 8 characters.");
    if (pw !== again) return setError("The two passwords don't match.");
    setBusy(true);
    const sb = supabase();
    const { error: err } = await sb.auth.updateUser({ password: pw });
    if (err) {
      setBusy(false);
      return setError(err.code === "weak_password" ? "Choose a longer password: at least 8 characters." : err.code === "same_password" ? "Choose a password different from the old one." : friendlyError(err));
    }
    // A new password signs out every other device; this one continues.
    await sb.auth.signOut({ scope: "others" });
    const { data: status } = await sb.rpc("my_account_status");
    setBusy(false);
    if (status === "active") return router.replace("/");
    await sb.auth.signOut({ scope: "local" });
    router.replace(`/login?error=${status === "inactive" ? "inactive" : "not-linked"}`);
  }

  return (
    <div className="center-screen">
      <div className="card glass elevated auth-card">
        <div className="auth-brand"><BrandMark /><strong>{BRAND.appName}</strong></div>
        <form onSubmit={save} noValidate className="form-grid">
          <h1 className="section-title">Choose a new password</h1>
          {error ? <div className="alert danger" role="alert">{error}</div> : null}
          {ready ? (
            <>
              <FormInput label="New password" name="password" type="password" autoComplete="new-password" helper="At least 8 characters." required />
              <FormInput label="Type it again" name="again" type="password" autoComplete="new-password" required />
              <Button type="submit" variant="primary" loading={busy}>Save password</Button>
            </>
          ) : null}
        </form>
      </div>
    </div>
  );
}
