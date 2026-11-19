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
  "signed-out": "Your session ended (signed out on another tab or device, or it expired). Sign in again.",
  server: "Couldn't reach the server. Check your internet and try again.",
  "wait-minute": "A reset link was sent a moment ago. Wait a minute before asking again.",
  "not-linked": "This login isn't linked to an employee record yet. Ask your HR team to add you with this exact e-mail address.",
  "not-registered": "This e-mail isn't set up in AttendOS yet. Ask your HR team to add you with your work e-mail.",
  "weak-password": "Choose a longer password: at least 8 characters.",
  "short-password": "Choose a password of at least 8 characters.",
  mismatch: "The two passwords don't match.",
  "link-expired": "That link has expired or was already used. Sign in, or ask for a new link below.",
  "too-many": "Too many e-mails were sent just now. Wait a few minutes and try again.",
};

/** Maps Supabase Auth errors to the messages above. */
function authCode(err: { code?: string; status?: number; message?: string } | null): string {
  const code = err?.code ?? "";
  const msg = err?.message ?? "";
  if (code === "invalid_credentials") return "invalid";
  if (code === "email_not_confirmed") return "unconfirmed";
  if (code === "weak_password") return "weak-password";
  if (/rate.?limit|over_email_send/i.test(code) || /seconds|rate limit/i.test(msg)) return "too-many";
  if (/isn't set up in AttendOS/i.test(msg)) return "not-registered";
  return "server";
}

type Mode = "signin" | "signup" | "forgot";

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
  const [mode, setMode] = useState<Mode>(params.get("mode") === "signup" ? "signup" : "signin");
  const [sent, setSent] = useState<string | null>(null);
  const [lastEmail, setLastEmail] = useState("");
  const [resent, setResent] = useState(false);
  const switchTo = (m: Mode) => { setMode(m); setError(null); setSent(null); setResent(false); };
  const configured = isConfigured();
  // Company sign-in address: /login?company=acme shows that company's name and logo.
  const [brand, setBrand] = useState<{ name: string; app_name: string | null; logo_url: string | null } | null>(null);
  const slug = params.get("company");
  useEffect(() => {
    if (!configured || !slug) return;
    supabase()
      .rpc("company_brand", { p_slug: slug })
      .then(({ data }) => setBrand(Array.isArray(data) && data[0] ? data[0] : null));
  }, [configured, slug]);

  // Links from Supabase e-mails come back with either a session (#access_token=…) or an error
  // (#error_code=otp_expired…). A session from a confirmation link is checked like a normal sign-in.
  useEffect(() => {
    if (!configured) return;
    const hash = new URLSearchParams(window.location.hash.slice(1));
    if (hash.get("error_code") || hash.get("error")) {
      setError("link-expired");
      return;
    }
    supabase().auth.getSession().then(async ({ data }) => {
      if (!data.session || ["inactive", "not-linked", "signed-out"].includes(params.get("error") ?? "")) return;
      const next = await accessCheck();
      if (next) setError(next);
      else router.replace("/");
    });
  }, [configured, router, params]);

  /** After a sign-in: null when the login may enter, otherwise the message to show (and the login is signed out). */
  async function accessCheck(): Promise<string | null> {
    const sb = supabase();
    const { data: status, error: err } = await sb.rpc("my_account_status");
    if (err) return "server";
    if (status === "active") return null;
    await sb.auth.signOut({ scope: "local" });
    return status === "inactive" ? "inactive" : "not-linked";
  }

  async function signIn(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const email = String(fd.get("email") ?? "").trim().toLowerCase();
    const password = String(fd.get("password") ?? "");
    if (!email || !password) return setError("missing");
    setBusy(true);
    setError(null);
    const sb = supabase();
    setLastEmail(email);
    const { data, error: err } = await sb.auth.signInWithPassword({ email, password });
    if (err || !data.user) {
      setBusy(false);
      return setError(authCode(err));
    }
    // The login must be linked to an active employee record (linked by confirmed work e-mail).
    const next = await accessCheck();
    setBusy(false);
    if (next) return setError(next);
    router.replace("/");
  }

  async function signUp(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const email = String(fd.get("email") ?? "").trim().toLowerCase();
    const password = String(fd.get("password") ?? "");
    if (!email || !password) return setError("missing");
    if (password.length < 8) return setError("short-password");
    if (password !== String(fd.get("again") ?? "")) return setError("mismatch");
    setBusy(true);
    setError(null);
    const back = `${window.location.origin}/login?confirmed=1${slug ? `&company=${encodeURIComponent(slug)}` : ""}`;
    const { error: err } = await supabase().auth.signUp({ email, password, options: { emailRedirectTo: back } });
    setBusy(false);
    if (err) return setError(authCode(err));
    setLastEmail(email);
    setSent(email);
  }

  async function resendConfirmation() {
    if (!lastEmail) return;
    setBusy(true);
    const back = `${window.location.origin}/login?confirmed=1${slug ? `&company=${encodeURIComponent(slug)}` : ""}`;
    const { error: err } = await supabase().auth.resend({ type: "signup", email: lastEmail, options: { emailRedirectTo: back } });
    setBusy(false);
    if (err) return setError(authCode(err));
    setResent(true);
  }

  async function sendReset(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const email = String(new FormData(e.currentTarget).get("email") ?? "").trim().toLowerCase();
    if (!email) return setError("missing");
    setBusy(true);
    const { error: err } = await supabase().auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/reset-password` });
    setBusy(false);
    if (err && (/seconds/i.test(err.message) || /rate/i.test(err.code ?? ""))) return setError("wait-minute");
    if (err && err.status !== 400) return setError("server");
    setError(null);
    setSent(email);
  }

  return (
    <div className="center-screen">
      <div className="auth-theme"><ThemeToggle /></div>
      <div className="card glass elevated auth-card">
        <div className="auth-brand">
          {brand?.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img className="brand-mark brand-logo" src={brand.logo_url} alt="" width={34} height={34} />
          ) : (
            <BrandMark />
          )}
          <div>
            <strong>{brand ? brand.app_name || brand.name : BRAND.appName}</strong>
            <span className="meta block">{brand ? (brand.app_name ? brand.name : BRAND.tagline) : BRAND.tagline}</span>
          </div>
        </div>
        {!configured ? (
          <div className="alert warning" role="note">
            This copy isn&apos;t connected to a database yet, so there is nothing to sign in to. <Link href="/">Open the design preview</Link>.
          </div>
        ) : mode === "forgot" ? (
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
            <button type="button" className="link-btn" onClick={() => switchTo("signin")}>Back to sign in</button>
          </form>
        ) : mode === "signup" ? (
          <form onSubmit={signUp} noValidate className="form-grid">
            <h1 className="section-title">Create your login</h1>
            {sent ? (
              <div className="alert success" role="status">
                We sent a confirmation link to {sent}. Open it on this device to finish. Check Spam if it doesn&apos;t arrive in a few minutes.
              </div>
            ) : (
              <>
                <p className="meta">For people your HR team has already added. Use your work e-mail exactly as HR entered it.</p>
                {error && ERRORS[error] ? <div className="alert danger" role="alert">{ERRORS[error]}</div> : null}
                <FormInput label="Work email" name="email" type="email" autoComplete="email" required />
                <FormInput label="Choose a password" name="password" type="password" autoComplete="new-password" helper="At least 8 characters." required />
                <FormInput label="Type it again" name="again" type="password" autoComplete="new-password" required />
                <Button type="submit" variant="primary" size="lg" loading={busy}>Create login</Button>
              </>
            )}
            <button type="button" className="link-btn" onClick={() => switchTo("signin")}>I already have a login</button>
          </form>
        ) : (
          <form onSubmit={signIn} noValidate className="form-grid">
            <h1 className="section-title">Sign in</h1>
            {params.get("confirmed") && !error ? <div className="alert success" role="status">Your e-mail is confirmed. Sign in to continue.</div> : null}
            {error && ERRORS[error] ? <div className="alert danger" role="alert">{ERRORS[error]}</div> : null}
            {error === "unconfirmed" && lastEmail ? (
              resent ? (
                <p className="meta">A new confirmation link is on its way to {lastEmail}.</p>
              ) : (
                <Button variant="ghost" size="sm" loading={busy} onClick={resendConfirmation}>Send the confirmation e-mail again</Button>
              )
            ) : null}
            <FormInput label="Work email" name="email" type="email" autoComplete="email" required />
            <FormInput label="Password" name="password" type="password" autoComplete="current-password" required />
            <Button type="submit" variant="primary" size="lg" loading={busy}>{busy ? "Signing in…" : "Sign in"}</Button>
            <div className="row auth-links">
              <button type="button" className="link-btn" onClick={() => switchTo("forgot")}>Forgot password?</button>
              <button type="button" className="link-btn" onClick={() => switchTo("signup")}>First time here? Create your login</button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
