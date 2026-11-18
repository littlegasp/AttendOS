"use client";

import Link from "next/link";
import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { BrandMark } from "@/components/AppSidebar";
import { ThemeToggle } from "@/components/ThemeToggle";
import { Button, FormInput } from "@/components/ui";
import { BRAND } from "@/lib/brand";
import { isConfigured, supabase } from "@/lib/supabase";

const ERRORS: Record<string, string> = {
  missing: "Enter your email and password.",
  invalid: "That email and password don't match. Check them and try again.",
  inactive: `Your login is switched off. Contact ${BRAND.supportContact}.`,
  unconfirmed: "This login hasn't been confirmed yet. Check your email for the confirmation link.",
  "signed-out": "You were signed out in another tab. Sign in again.",
  server: "Couldn't reach the server. Check your internet and try again.",
  "wait-minute": "A reset link was sent a moment ago. Wait a minute before asking again.",
};

export default function LoginPage() {
  return (
    <Suspense>
      <Login />
    </Suspense>
  );
}

function Login() {
  const router = useRouter();
  const params = useSearchParams();
  const [error, setError] = useState<string | null>(params.get("error"));
  const [busy, setBusy] = useState(false);
  const [forgot, setForgot] = useState(false);
  const [sent, setSent] = useState<string | null>(null);
  const configured = isConfigured();

  useEffect(() => {
    if (!configured) return;
    supabase().auth.getSession().then(({ data }) => {
      if (data.session && params.get("error") !== "inactive") router.replace("/");
    });
  }, [configured, router, params]);

  async function signIn(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const email = String(fd.get("email") ?? "").trim().toLowerCase();
    const password = String(fd.get("password") ?? "");
    if (!email || !password) return setError("missing");
    setBusy(true);
    setError(null);
    const sb = supabase();
    const { data, error: err } = await sb.auth.signInWithPassword({ email, password });
    if (err || !data.user) {
      setBusy(false);
      const code = (err as { code?: string } | null)?.code;
      return setError(code === "invalid_credentials" ? "invalid" : code === "email_not_confirmed" ? "unconfirmed" : "server");
    }
    const { data: me } = await sb.from("employees").select("active").eq("id", data.user.id).maybeSingle();
    if (!me?.active) {
      await sb.auth.signOut({ scope: "local" });
      setBusy(false);
      return setError("inactive");
    }
    router.replace("/");
  }

  async function sendReset(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const email = String(new FormData(e.currentTarget).get("email") ?? "").trim().toLowerCase();
    if (!email) return setError("missing");
    setBusy(true);
    const { error: err } = await supabase().auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/reset-password` });
    setBusy(false);
    if (err && /seconds/i.test(err.message)) return setError("wait-minute");
    if (err && err.status !== 400) return setError("server");
    setError(null);
    setSent(email);
  }

  return (
    <div className="center-screen">
      <div className="auth-theme"><ThemeToggle /></div>
      <div className="card glass elevated auth-card">
        <div className="auth-brand">
          <BrandMark />
          <div>
            <strong>{BRAND.appName}</strong>
            <span className="meta block">{BRAND.company === BRAND.appName ? BRAND.tagline : BRAND.company}</span>
          </div>
        </div>
        {!configured ? (
          <div className="alert warning" role="note">
            This copy isn&apos;t connected to a database yet, so there is nothing to sign in to. <Link href="/">Open the design preview</Link>.
          </div>
        ) : forgot ? (
          <form onSubmit={sendReset} noValidate className="form-grid">
            <h1 className="section-title">Reset your password</h1>
            {sent ? (
              <div className="alert success" role="status">If {sent} has a login, a reset link is on its way. Check Spam if it doesn&apos;t arrive in a few minutes.</div>
            ) : (
              <>
                {error && ERRORS[error] ? <div className="alert danger" role="alert">{ERRORS[error]}</div> : null}
                <FormInput label="Work email" name="email" type="email" autoComplete="email" required />
                <Button type="submit" variant="primary" loading={busy}>Send reset link</Button>
              </>
            )}
            <button type="button" className="link-btn" onClick={() => { setForgot(false); setError(null); setSent(null); }}>Back to sign in</button>
          </form>
        ) : (
          <form onSubmit={signIn} noValidate className="form-grid">
            <h1 className="section-title">Sign in</h1>
            {error && ERRORS[error] ? <div className="alert danger" role="alert">{ERRORS[error]}</div> : null}
            <FormInput label="Work email" name="email" type="email" autoComplete="email" required />
            <FormInput label="Password" name="password" type="password" autoComplete="current-password" required />
            <Button type="submit" variant="primary" size="lg" loading={busy}>{busy ? "Signing in…" : "Sign in"}</Button>
            <button type="button" className="link-btn" onClick={() => { setForgot(true); setError(null); }}>Forgot password?</button>
          </form>
        )}
      </div>
    </div>
  );
}
