"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Button, FormInput, FormSelect, FormTextarea, GlassCard, MetricCard, SectionCard, StatusBadge, type AttendanceStatus } from "@/components/ui";
import {
  batchAction, CODE_TEXT, datErrorText, type DatBatch, type DatCode, type DatRow, type DatState, downloadOriginal, DUP_TEXT, FLAG_TEXT, fmtBytes,
  listBatches, loadCodes, loadRows, MAP_TEXT, type RowFilter, sha256Hex, showSpaces, STATE_TEXT, TIME_TEXT, uploadDat, type UploadProgress,
} from "@/lib/dat-import";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { MappingForm } from "./Mapping";
import { fmtTime, useDemo } from "./shared";

const PAGE = 100;

const STATE_BADGE: Record<DatState, AttendanceStatus> = {
  uploading: "pending", uploaded: "pending", parsing: "pending", classifying: "pending",
  ready_for_review: "pending", reviewed: "approved", failed: "failed", expired: "weekly-off", cancelled: "weekly-off", deleted: "weekly-off",
};
const IN_PROGRESS: DatState[] = ["uploading", "uploaded", "parsing", "classifying"];

/**
 * B5 offline DAT import (Admin). The X2008 USB export is kept exactly as exported; every line is shown for review.
 * Nothing here adds attendance, works out IN/OUT, or gives the unnamed fields a meaning.
 */
export function DatImport() {
  const { live, may } = useDemo();
  const [batches, setBatches] = useState<DatBatch[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const reload = useCallback(async () => {
    try {
      const r = await listBatches(supabase());
      setBatches(r.batches);
      setError(null);
    } catch (e) {
      setError(friendlyError(e));
    }
  }, []);
  useEffect(() => {
    if (live && may("importBiometricFiles")) void reload();
  }, [live, may, reload]);

  if (!live) {
    return (
      <GlassCard>
        <EmptyState title="File import works with company records only" body="Importing a device export file needs the company database. This demonstration has no file import." />
      </GlassCard>
    );
  }
  if (!may("importBiometricFiles")) {
    return <GlassCard><EmptyState title="Only an Admin imports device files" body="Ask an Admin to import the file. You can map employee codes in Employee mapping." /></GlassCard>;
  }
  if (error && !batches) return <GlassCard><ErrorState title="Couldn't load the imports" body={error} onRetry={reload} /></GlassCard>;
  if (!batches) return <LoadingState kind="table" />;
  const current = open ? batches.find((b) => b.id === open) ?? null : null;

  return (
    <div className="stack">
      <div className="alert info" role="note">
        <div>
          <strong>Raw records only.</strong>
          <p className="small">
            The file is kept exactly as exported. Every line is shown here with its original fields and time. Nothing is added to attendance,
            no IN or OUT is worked out, and the fields whose meaning is not documented (fields 3–6) are shown as they are.
          </p>
        </div>
      </div>
      {current ? (
        <BatchReview batch={current} onBack={() => setOpen(null)} onChanged={reload} />
      ) : (
        <>
          <UploadCard onDone={async (id) => { await reload(); if (id) setOpen(id); }} />
          <BatchList batches={batches} onOpen={setOpen} onChanged={reload} />
        </>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ upload */

function UploadCard({ onDone }: { onDone: (batchId: string | null) => void }) {
  const { state, tz } = useDemo();
  const devices = state.devices.filter((d) => d.manufacturer === "essl" && !d.disabled);
  const [device, setDevice] = useState(devices[0]?.id ?? "");
  const [zone, setZone] = useState(tz);
  const [file, setFile] = useState<{ name: string; bytes: Uint8Array; sha: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<UploadProgress | null>(null);
  const [error, setError] = useState<string | null>(null);

  const pick = async (f: File | undefined) => {
    setError(null);
    setFile(null);
    if (!f) return;
    const bytes = new Uint8Array(await f.arrayBuffer());
    setFile({ name: f.name, bytes, sha: await sha256Hex(bytes) });
  };

  const run = async () => {
    if (!file || !device) return;
    setBusy(true);
    setError(null);
    try {
      const r = await uploadDat(supabase(), file, device, zone.trim(), { onProgress: setProgress });
      if (r.error) {
        setError(datErrorText(r.error) + (r.detail && typeof r.detail.line === "number" ? ` (line ${r.detail.line})` : ""));
        if (r.error === "already_imported" && r.batchId) onDone(r.batchId);
        else onDone(null);
      } else {
        toast({ tone: "success", title: "File imported for review", body: "Every line is kept. Nothing was added to attendance." });
        setFile(null);
        onDone(r.batchId);
      }
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
      setProgress(null);
    }
  };

  if (!devices.length) {
    return (
      <SectionCard title="Import a device file" subtitle="eSSL X2008 attendance export (.dat from the USB stick)">
        <EmptyState title="No eSSL device registered" body="Add the eSSL device the file comes from in Devices (connection: File import), then import its file here." />
      </SectionCard>
    );
  }
  return (
    <SectionCard title="Import a device file" subtitle="eSSL X2008 attendance export (.dat from the USB stick) — format essl.x2008.attlog/1">
      <div className="stack">
        <div className="form-2">
          <FormSelect label="Device the file comes from" required value={device} onChange={(e) => setDevice(e.target.value)} options={devices.map((d) => ({ value: d.id, label: `${d.name} · ${d.model}` }))} />
          <FormInput label="Time zone of the device clock" required value={zone} onChange={(e) => setZone(e.target.value)} helper="The file has no time zone. The original times are kept as written; this zone is only used to place them in time." />
        </div>
        <FormInput
          label="Original export file"
          type="file"
          accept=".dat,text/plain"
          required
          disabled={busy}
          onChange={(e) => void pick(e.target.files?.[0])}
          helper="Choose the file exactly as it came from the device. Don't open and save it in Excel or another program first."
        />
        {file ? (
          <dl className="bio-dl small">
            <div><dt>File</dt><dd className="mono bio-wrap">{file.name}</dd></div>
            <div><dt>Size</dt><dd>{fmtBytes(file.bytes.length)}</dd></div>
            <div><dt>Check value (SHA-256)</dt><dd className="mono bio-wrap">{file.sha}</dd></div>
          </dl>
        ) : null}
        {progress ? (
          <div className="stack bio-progress-wrap" aria-live="polite">
            <progress className="bio-progress" max={Math.max(progress.total, 1)} value={progress.done} aria-label="Import progress" />
            <p className="meta">
              {progress.phase === "hashing" ? "Preparing the file…" : progress.phase === "uploading" ? `Uploading part ${Math.min(progress.done + 1, progress.total)} of ${progress.total}…`
                : progress.phase === "checking" ? `Checking lines${progress.total ? ` (${progress.done} of ${progress.total})` : ""}…` : "Done"}
            </p>
          </div>
        ) : null}
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <div className="row">
          <Button variant="primary" onClick={run} disabled={!file || !device || !zone.trim()} loading={busy}>Upload and check</Button>
        </div>
      </div>
    </SectionCard>
  );
}

/* ------------------------------------------------------------------ list */

function BatchList({ batches, onOpen, onChanged }: { batches: DatBatch[]; onOpen: (id: string) => void; onChanged: () => void }) {
  const { tz } = useDemo();
  const [deleting, setDeleting] = useState<DatBatch | null>(null);
  const cancel = async (b: DatBatch) => {
    const err = await batchAction(supabase(), "biometric_dat_cancel", { p_batch: b.id }).catch(friendlyError);
    toast(err ? { tone: "danger", title: "Not cancelled", body: err } : { tone: "success", title: "Upload cancelled", body: "Nothing of it was kept." });
    onChanged();
  };
  if (!batches.length) {
    return <SectionCard title="Imported files"><EmptyState title="No files imported yet" body="Imported files appear here with every line kept for review." /></SectionCard>;
  }
  return (
    <SectionCard title="Imported files" subtitle="Newest first. A file can be imported once; a refused or deleted import can be repeated.">
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th scope="col">File</th><th scope="col">Device</th><th scope="col">Status</th><th scope="col" className="num">Lines</th>
              <th scope="col">Imported</th><th scope="col"><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            {batches.map((b) => (
              <tr key={b.id}>
                <th scope="row" className="bio-wrap">
                  {b.state === "ready_for_review" || b.state === "reviewed"
                    ? <button type="button" className="link-btn mono bio-wrap" onClick={() => onOpen(b.id)}>{b.file_name}</button>
                    : <span className="mono">{b.state === "deleted" ? "(deleted)" : b.file_name}</span>}
                  <span className="tiny muted block mono" title={b.sha256}>SHA-256 {b.sha256.slice(0, 12)}…</span>
                </th>
                <td className="bio-wrap">{b.device_name ?? "—"}</td>
                <td>
                  <StatusBadge status={STATE_BADGE[b.state]} label={STATE_TEXT[b.state]} />
                  {b.fail_reason ? <span className="tiny block text-danger-strong">{datErrorText(b.fail_reason)}{b.fail_line ? ` (line ${b.fail_line})` : ""}</span> : null}
                  {b.state === "uploading" ? <span className="tiny block muted">{b.next_index} of {b.chunk_count} parts received{b.mine ? " — choose the same file above to continue" : ""}</span> : null}
                </td>
                <td className="num">{b.lines ?? "—"}</td>
                <td className="small">{fmtTime(b.created_at, tz)}<span className="tiny muted block">{b.uploaded_by ?? ""}</span></td>
                <td>
                  <div className="row bio-actions">
                    {b.state === "ready_for_review" || b.state === "reviewed" ? <Button size="sm" onClick={() => onOpen(b.id)}>Open</Button> : null}
                    {IN_PROGRESS.includes(b.state) ? <button type="button" className="link-btn small" onClick={() => void cancel(b)}>Cancel</button> : null}
                    {["ready_for_review", "reviewed", "failed", "expired", "cancelled"].includes(b.state) ? <button type="button" className="link-btn small" onClick={() => setDeleting(b)}>Delete</button> : null}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {deleting ? <DeleteDialog batch={deleting} onClose={() => setDeleting(null)} onDone={onChanged} /> : null}
    </SectionCard>
  );
}

function DeleteDialog({ batch, onClose, onDone }: { batch: DatBatch; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <Modal open title="Delete this import" subtitle={batch.state === "deleted" ? "" : batch.file_name} onClose={onClose}>
      <form
        className="stack"
        onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          const err = await batchAction(supabase(), "biometric_dat_delete", { p_batch: batch.id, p_reason: reason }).catch(friendlyError);
          setBusy(false);
          if (err) return setError(err);
          toast({ tone: "success", title: "Import deleted", body: "The file and its lines were removed. The record of the import and its history stay." });
          onDone();
          onClose();
        }}
      >
        <p className="small">The stored file and all its lines are removed. The import stays listed as deleted (size, check value, who and when), and its history is kept. Nothing in attendance changes.</p>
        <FormTextarea label="Reason" required rows={2} value={reason} onChange={(e) => setReason(e.target.value)} helper="At least 5 characters. Kept with the import." />
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="danger" loading={busy}>Delete import</Button>
        </div>
      </form>
    </Modal>
  );
}

/* ------------------------------------------------------------------ review */

function BatchReview({ batch, onBack, onChanged }: { batch: DatBatch; onBack: () => void; onChanged: () => void }) {
  const { tz, may } = useDemo();
  const [codes, setCodes] = useState<{ codes: DatCode[]; invalid_codes: number; totals: Record<string, number> } | null>(null);
  const [filter, setFilter] = useState<RowFilter>("all");
  const [code, setCode] = useState<string | null>(null);
  const [offset, setOffset] = useState(0);
  const [rows, setRows] = useState<{ total: number; rows: DatRow[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [mapping, setMapping] = useState<string | null>(null);
  const [reviewing, setReviewing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [rev, setRev] = useState(0);

  useEffect(() => {
    let live = true;
    loadCodes(supabase(), batch.id).then((c) => live && setCodes(c)).catch((e) => live && setError(friendlyError(e)));
    return () => { live = false; };
  }, [batch.id, rev]);
  useEffect(() => {
    let live = true;
    setRows(null);
    loadRows(supabase(), batch.id, filter, code, offset, PAGE).then((r) => live && setRows(r)).catch((e) => live && setError(friendlyError(e)));
    return () => { live = false; };
  }, [batch.id, filter, code, offset, rev]);

  const c = batch.counts;
  const dups = (c.exact_in_file ?? 0) + (c.exact_in_earlier_import ?? 0) + (c.same_code_time_other_fields ?? 0) + (c.already_from_device ?? 0);
  const setF = (f: RowFilter, cd: string | null = null) => { setFilter(f); setCode(cd); setOffset(0); };
  const download = async () => {
    const r = await downloadOriginal(supabase(), batch.id).catch((e) => ({ error: friendlyError(e) }));
    if ("error" in r) return toast({ tone: "danger", title: "Couldn't download", body: r.error });
    const url = URL.createObjectURL(new Blob([r.bytes as unknown as BlobPart], { type: "application/octet-stream" }));
    const a = document.createElement("a");
    a.href = url; a.download = r.name; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  return (
    <div className="stack">
      <div className="row bio-head-row">
        <button type="button" className="link-btn" onClick={onBack}>← All imported files</button>
      </div>
      <SectionCard
        title="Import review"
        subtitle={`${batch.device_name ?? "Device"} · imported ${fmtTime(batch.created_at, tz)}${batch.uploaded_by ? ` by ${batch.uploaded_by}` : ""}`}
        actions={
          <>
            <Button size="sm" onClick={download}>Download original</Button>
            {batch.state === "ready_for_review" ? <Button size="sm" variant="primary" onClick={() => setReviewing(true)}>Mark as reviewed</Button> : null}
            <Button size="sm" variant="danger" onClick={() => setDeleting(true)}>Delete</Button>
          </>
        }
      >
        <div className="stack">
          <dl className="bio-dl small">
            <div><dt>File</dt><dd className="mono bio-wrap">{batch.file_name}</dd></div>
            <div><dt>Status</dt><dd><StatusBadge status={STATE_BADGE[batch.state]} label={STATE_TEXT[batch.state]} />{batch.reviewed_at ? <span className="tiny muted"> {batch.reviewed_by} · {fmtTime(batch.reviewed_at, tz)}</span> : null}</dd></div>
            <div><dt>Size</dt><dd>{batch.size !== null ? fmtBytes(batch.size) : "—"}</dd></div>
            <div><dt>Check value (SHA-256)</dt><dd className="mono bio-wrap">{batch.sha256}</dd></div>
            <div><dt>Format</dt><dd className="mono">{batch.format_version}</dd></div>
            <div><dt>Device time zone (declared)</dt><dd>{batch.timezone}</dd></div>
            <div><dt>Line endings</dt><dd>Windows (CRLF){batch.final_terminator === "none" ? "; last line without line ending" : ""}{batch.bom === "utf8" ? "; starts with a byte-order mark" : ""}</dd></div>
          </dl>
          <div className="grid-kpi bio-kpis">
            <MetricCard label="Lines" value={c.lines ?? 0} note={`${c.ok ?? 0} read as records`} />
            <MetricCard label="Not readable" value={(c.unparsable ?? 0) + (c.blank ?? 0)} tone={(c.unparsable ?? 0) + (c.blank ?? 0) ? "warning" : "neutral"} note={`${c.unparsable ?? 0} malformed, ${c.blank ?? 0} empty — kept`} />
            <MetricCard label="Repeated records" value={dups} tone={dups ? "warning" : "neutral"} note="Labelled, never removed" />
            <MetricCard label="Device codes" value={c.codes ?? 0} note={codes ? `${codes.invalid_codes} lines without a usable code` : "Counting…"} />
            <MetricCard label="Records with a mapping" value={codes ? (codes.totals.mapped ?? 0) + (codes.totals.inactive ?? 0) : null} tone="success" note="At the time of each record" />
            <MetricCard label="Records not mapped" value={codes ? (codes.totals.unmapped ?? 0) + (codes.totals.undetermined ?? 0) : null} tone={codes && (codes.totals.unmapped ?? 0) ? "warning" : "neutral"} note="Kept for review" />
          </div>
          {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        </div>
      </SectionCard>

      <SectionCard title="Device codes in this file" subtitle="A code becomes a person only through an approved mapping that covers the record's time. Nothing is mapped automatically.">
        {!codes ? <LoadingState kind="table" /> : !codes.codes.length ? <EmptyState title="No usable codes" body="No line has a usable device code." /> : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr><th scope="col">Device code</th><th scope="col" className="num">Records</th><th scope="col">First record</th><th scope="col">Last record</th><th scope="col">AttendOS employee</th><th scope="col"><span className="sr-only">Actions</span></th></tr>
              </thead>
              <tbody>
                {codes.codes.map((k) => (
                  <tr key={k.code}>
                    <th scope="row" className="mono">{k.code}</th>
                    <td className="num">{k.records}</td>
                    <td className="mono small">{k.first}</td>
                    <td className="mono small">{k.last}</td>
                    <td className="bio-wrap">
                      {k.employees.map((e) => (
                        <span key={e.employee_id} className="block">
                          {e.full_name} <span className="tiny muted mono">{e.emp_code ?? ""}</span>
                          <span className="tiny muted"> · {e.scope === "device" ? "this device" : "company-wide"} · {e.records} of {k.records}</span>
                          {!e.active ? <span className="tiny text-warning"> · switched off</span> : null}
                        </span>
                      ))}
                      {k.unmapped + k.undetermined > 0 ? <StatusBadge status="pending" label={`${k.unmapped + k.undetermined} not mapped`} /> : null}
                    </td>
                    <td>
                      <div className="row bio-actions">
                        <button type="button" className="link-btn small" onClick={() => setF("code", k.code)}>Show records</button>
                        {k.unmapped > 0 && may("mapBiometricCodes") ? <button type="button" className="link-btn small" onClick={() => setMapping(k.code)}>Map code</button> : null}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>

      <SectionCard title="Records" subtitle="Every line of the file, in file order, with its original fields. Fields 3–6 are kept exactly; their meaning is not documented.">
        <div className="stack">
          <div className="row bio-filters" role="group" aria-label="Show">
            {(["all", "problems", "duplicates", "unmapped"] as RowFilter[]).map((f) => (
              <button key={f} type="button" className={`btn sm ${filter === f ? "primary" : "secondary"}`} aria-pressed={filter === f} onClick={() => setF(f)}>
                {{ all: "All lines", problems: "Needs a look", duplicates: "Repeated", unmapped: "Not mapped", code: "" }[f]}
              </button>
            ))}
            {filter === "code" ? <span className="badge tone-info">Code <span className="mono">&nbsp;{code}</span> <button type="button" className="link-btn tiny" onClick={() => setF("all")}>clear</button></span> : null}
          </div>
          {!rows ? <LoadingState kind="table" /> : !rows.rows.length ? <EmptyState title="Nothing here" body="No line matches this view." /> : (
            <>
              <div className="table-wrap">
                <table className="table bio-dat-rows">
                  <thead>
                    <tr>
                      <th scope="col" className="num">Line</th>
                      <th scope="col">Field 1 (as written)</th>
                      <th scope="col">Code</th>
                      <th scope="col">Date and time (as written)</th>
                      <th scope="col">Field 3</th><th scope="col">Field 4</th><th scope="col">Field 5</th><th scope="col">Field 6</th>
                      <th scope="col">Checks</th>
                      <th scope="col">Employee</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.rows.map((r) => <RowView key={r.line} r={r} />)}
                  </tbody>
                </table>
              </div>
              <div className="pager">
                <Button size="sm" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))}>Previous</Button>
                <span className="meta">Lines {offset + 1}–{Math.min(offset + PAGE, rows.total)} of {rows.total}</span>
                <Button size="sm" disabled={offset + PAGE >= rows.total} onClick={() => setOffset(offset + PAGE)}>Next</Button>
              </div>
            </>
          )}
        </div>
      </SectionCard>

      {mapping !== null ? (
        <MappingForm open code={mapping} deviceId={batch.source_device_id ?? undefined} onClose={() => { setMapping(null); setRev((x) => x + 1); }} />
      ) : null}
      {reviewing ? <ReviewDialog batch={batch} onClose={() => setReviewing(false)} onDone={onChanged} /> : null}
      {deleting ? <DeleteDialog batch={batch} onClose={() => setDeleting(false)} onDone={() => { onChanged(); onBack(); }} /> : null}
    </div>
  );
}

function RowView({ r }: { r: DatRow }) {
  const checks = useMemo(() => {
    const out: { text: string; tone: "warning" | "danger" | "info" | "neutral" }[] = [];
    if (r.parse_status === "blank") out.push({ text: "Empty line", tone: "warning" });
    if (r.parse_status === "unparsable") {
      const reason = r.parse_reason ?? "";
      out.push({ text: reason.startsWith("field_count_") ? `${reason.replace("field_count_", "")} fields (6 expected)` : reason.startsWith("code_") ? CODE_TEXT[r.code_status ?? ""] ?? reason : TIME_TEXT.bad_format, tone: "danger" });
    }
    if (r.time_status && r.time_status !== "ok" && r.time_status !== "bad_format") out.push({ text: TIME_TEXT[r.time_status] ?? r.time_status, tone: "danger" });
    if (r.dup_class && r.dup_class !== "new") {
      out.push({ text: `${DUP_TEXT[r.dup_class]}${r.dup_ref_line ? ` (line ${r.dup_ref_line}${r.dup_class === "exact_in_earlier_import" || (r.dup_class === "same_code_time_other_fields" && r.dup_ref_batch) ? " of an earlier import" : ""})` : ""}`, tone: "info" });
    }
    for (const f of r.flags) out.push({ text: FLAG_TEXT[f] ?? f, tone: "neutral" });
    return out;
  }, [r]);
  const f = r.fields;
  const six = f.length === 6;
  return (
    <tr>
      <td className="num mono">{r.line}</td>
      <td className="mono bio-raw" title="Spaces shown as ·">{six ? showSpaces(f[0]) : <span className="bio-wrap">{showSpaces(r.raw_line) || <span className="muted">(empty line)</span>}</span>}</td>
      <td className="mono">{r.code ?? <span className="muted">—</span>}</td>
      <td className="mono">{six ? f[1] : "—"}</td>
      <td className="mono">{six ? f[2] : ""}</td>
      <td className="mono">{six ? f[3] : ""}</td>
      <td className="mono">{six ? f[4] : ""}</td>
      <td className="mono">{six ? f[5] : ""}</td>
      <td className="small">
        {checks.length ? checks.map((c, i) => <span key={i} className={`badge tone-${c.tone} bio-check`}>{c.text}</span>) : <span className="muted">OK</span>}
      </td>
      <td className="small bio-wrap">
        {r.employee ? <>{r.employee.full_name}<span className="tiny muted block mono">{r.employee.emp_code ?? ""} · {r.scope === "device" ? "this device" : "company-wide"}</span></> : r.mapping_status ? <span className="muted">{MAP_TEXT[r.mapping_status] ?? r.mapping_status}</span> : null}
      </td>
    </tr>
  );
}

function ReviewDialog({ batch, onClose, onDone }: { batch: DatBatch; onClose: () => void; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <Modal open title="Mark this import as reviewed" subtitle={batch.file_name} onClose={onClose}>
      <div className="stack">
        <p className="small">This records that you have looked at the lines, repeated records and unmapped codes of this file. Nothing is added to attendance, and no punch is created.</p>
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            loading={busy}
            onClick={async () => {
              setBusy(true);
              const err = await batchAction(supabase(), "biometric_dat_mark_reviewed", { p_batch: batch.id, p_version: batch.version }).catch(friendlyError);
              setBusy(false);
              if (err) return setError(err);
              toast({ tone: "success", title: "Marked as reviewed", body: "Recorded with your name and the time." });
              onDone();
              onClose();
            }}
          >
            Mark as reviewed
          </Button>
        </div>
      </div>
    </Modal>
  );
}
