import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import {
  DAT_CHUNK_BYTES, DAT_ERROR_TEXT, datErrorText, fromBase64, sha256Hex, showSpaces, splitChunks, toBase64, uploadDat,
  type RpcClient, type RpcResult,
} from "../src/lib/dat-import";
import { can, type Role } from "../src/lib/permissions";

const FIX = join(__dirname, "fixtures", "dat");
const hex = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

/* ------------------------------------------------------------------ in-memory stand-in for the 0013 upload protocol */

interface FakeOpts { dropAnswerOnce?: number; failNetworkOnce?: string; refuseBegin?: string; resumeFrom?: number; processSteps?: number }

function fakeServer(o: FakeOpts = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  let declared: { size: number; sha: string; hashes: string[] } | null = null;
  const stored = new Map<number, Uint8Array>();
  let next = o.resumeFrom ?? 0;
  let token = "t1";
  let state = "uploading";
  let steps = 0;
  let dropped = false;
  let netFailed = false;
  const answer = (data: unknown): RpcResult => ({ data, error: null });
  const sb: RpcClient = {
    rpc(fn, args = {}) {
      calls.push({ fn, args });
      if (o.failNetworkOnce === fn && !netFailed) { netFailed = true; return Promise.reject(new Error("fetch failed")); }
      switch (fn) {
        case "biometric_dat_begin": {
          if (o.refuseBegin) return Promise.resolve(answer({ ok: false, error: o.refuseBegin, batch_id: "b-old" }));
          declared = { size: Number(args.p_size), sha: String(args.p_sha256), hashes: args.p_chunk_hashes as string[] };
          return Promise.resolve(answer({ ok: true, batch_id: "b1", upload_token: token, next_index: 0 }));
        }
        case "biometric_dat_chunk": {
          if (args.p_token !== token) return Promise.resolve(answer({ ok: false, error: "taken_over" }));
          const i = Number(args.p_index);
          const bytes = fromBase64(String(args.p_data));
          if (i < next) return Promise.resolve(answer(hex(stored.get(i) ?? new Uint8Array()) === hex(bytes) ? { ok: true, repeat: true, next_index: next } : { ok: false, error: "chunk_conflict" }));
          if (i > next) return Promise.resolve(answer({ ok: false, error: "wrong_order", expected_index: next }));
          if (hex(bytes) !== declared!.hashes[i]) return Promise.resolve(answer({ ok: false, error: "chunk_hash_mismatch", expected_index: next }));
          stored.set(i, bytes);
          next++;
          if (o.dropAnswerOnce === i && !dropped) { dropped = true; return Promise.reject(new Error("network: answer lost")); }
          return Promise.resolve(answer({ ok: true, next_index: next }));
        }
        case "biometric_dat_resume":
          token = "t2";
          return Promise.resolve(answer({ ok: true, upload_token: token, next_index: next, declared_sha256: declared!.sha, chunk_hashes: declared!.hashes, declared_size: declared!.size }));
        case "biometric_dat_finish": {
          if (next < declared!.hashes.length) return Promise.resolve(answer({ ok: false, error: "missing_chunks" }));
          const whole = new Uint8Array(declared!.size);
          let off = 0;
          for (let i = 0; i < declared!.hashes.length; i++) { whole.set(stored.get(i)!, off); off += stored.get(i)!.length; }
          if (hex(whole) !== declared!.sha) { state = "failed"; return Promise.resolve(answer({ ok: false, error: "hash_mismatch", state })); }
          state = "uploaded";
          return Promise.resolve(answer({ ok: true, state }));
        }
        case "biometric_dat_process": {
          steps++;
          if (steps < (o.processSteps ?? 3)) { state = "parsing"; return Promise.resolve(answer({ ok: true, state, progress_line: steps * 10, lines: 100 })); }
          state = "ready_for_review";
          return Promise.resolve(answer({ ok: true, state, progress_line: 100, lines: 100 }));
        }
      }
      return Promise.resolve({ data: null, error: { message: "unknown function " + fn } });
    },
  };
  return { sb, calls, stored: () => stored, setDeclared: (d: typeof declared) => { declared = d; } };
}

const noWait = () => Promise.resolve();
const bytesOf = (n: number, seed = 7) => Uint8Array.from({ length: n }, (_, i) => (i * 31 + seed) % 251);

/* ------------------------------------------------------------------ helpers */

test("sha256Hex equals Node's SHA-256; splitChunks covers every byte in 256 KiB pieces", async () => {
  const b = bytesOf(DAT_CHUNK_BYTES * 2 + 1234);
  assert.equal(await sha256Hex(b), hex(b));
  const parts = splitChunks(b);
  assert.deepEqual(parts.map((p) => p.length), [DAT_CHUNK_BYTES, DAT_CHUNK_BYTES, 1234]);
  assert.equal(hex(Uint8Array.from(parts.flatMap((p) => Array.from(p)))), hex(b));
});

test("base64 round-trips every byte value (incl. CR, LF, TAB, NUL, 0xFF)", () => {
  const all = Uint8Array.from({ length: 256 }, (_, i) => i);
  assert.deepEqual(fromBase64(toBase64(all)), all);
});

test("showSpaces makes left-padding visible without changing anything else", () => {
  assert.equal(showSpaces("       10"), "·······10");
  assert.equal(showSpaces("0010"), "0010");
});

test("every refusal the database can send has plain-language text", () => {
  const sql = readFileSync(join(__dirname, "..", "supabase", "migrations", "0013_biometric_dat_import.sql"), "utf8");
  const codes = new Set([...sql.matchAll(/'error', '([a-z_]+)'/g), ...sql.matchAll(/biometric_dat_fail\(b, '([a-z_]+)'/g), ...sql.matchAll(/fail_reason = '([a-z_]+)'/g)].map((m) => m[1]));
  assert.ok(codes.size >= 25, `found ${codes.size} codes`);
  for (const c of codes) assert.ok(DAT_ERROR_TEXT[c], `missing text for ${c}`);
  assert.equal(datErrorText("hash_mismatch").includes("Nothing was kept"), true);
});

/* ------------------------------------------------------------------ upload protocol */

test("upload: begin, all chunks in order, finish, process until ready — the server receives the exact bytes", async () => {
  const f = fakeServer();
  const b = bytesOf(DAT_CHUNK_BYTES + 500);
  const seen: string[] = [];
  const r = await uploadDat(f.sb, { name: "x.dat", bytes: b }, "dev", "Asia/Kolkata", { wait: noWait, onProgress: (p) => seen.push(p.phase) });
  assert.deepEqual(r, { batchId: "b1", state: "ready_for_review", error: null });
  const begin = f.calls.find((c) => c.fn === "biometric_dat_begin")!.args;
  assert.equal(begin.p_sha256, hex(b));
  assert.equal(begin.p_size, b.length);
  assert.deepEqual(begin.p_chunk_hashes, splitChunks(b).map(hex));
  assert.equal(f.calls.filter((c) => c.fn === "biometric_dat_chunk").length, 2);
  assert.deepEqual([...new Set(seen)], ["hashing", "uploading", "checking", "done"]);
});

test("upload: a lost answer is retried safely (the server sees an idempotent repeat)", async () => {
  const f = fakeServer({ dropAnswerOnce: 0 });
  const r = await uploadDat(f.sb, { name: "x.dat", bytes: bytesOf(DAT_CHUNK_BYTES + 10) }, "dev", "Asia/Kolkata", { wait: noWait });
  assert.equal(r.state, "ready_for_review");
  const idx = f.calls.filter((c) => c.fn === "biometric_dat_chunk").map((c) => c.args.p_index);
  assert.deepEqual(idx, [0, 0, 1]);
});

test("upload: a network failure on finish is retried", async () => {
  const f = fakeServer({ failNetworkOnce: "biometric_dat_finish" });
  const r = await uploadDat(f.sb, { name: "x.dat", bytes: bytesOf(100) }, "dev", "Asia/Kolkata", { wait: noWait });
  assert.equal(r.state, "ready_for_review");
  assert.equal(f.calls.filter((c) => c.fn === "biometric_dat_finish").length, 2);
});

test("upload: resume after refresh takes over with a new token and continues from the server's next index", async () => {
  const b = bytesOf(DAT_CHUNK_BYTES * 2 + 3);
  // the server already has this file declared and chunk 0 stored (an earlier tab)
  const f2 = fakeServer({ refuseBegin: "resume_available", resumeFrom: 1 });
  f2.setDeclared({ size: b.length, sha: hex(b), hashes: splitChunks(b).map(hex) });
  f2.stored().set(0, splitChunks(b)[0]);
  const r = await uploadDat(f2.sb, { name: "x.dat", bytes: b }, "dev", "Asia/Kolkata", { wait: noWait });
  assert.equal(r.state, "ready_for_review");
  const chunkCalls = f2.calls.filter((c) => c.fn === "biometric_dat_chunk");
  assert.deepEqual(chunkCalls.map((c) => c.args.p_index), [1, 2]);
  assert.ok(chunkCalls.every((c) => c.args.p_token === "t2"));
});

test("upload: resuming with a DIFFERENT file is refused before any byte is sent", async () => {
  const f = fakeServer({ refuseBegin: "resume_available", resumeFrom: 1 });
  f.setDeclared({ size: 10, sha: "0".repeat(64), hashes: ["0".repeat(64)] });
  const r = await uploadDat(f.sb, { name: "x.dat", bytes: bytesOf(10) }, "dev", "Asia/Kolkata", { wait: noWait });
  assert.equal(r.error, "chunk_conflict");
  assert.equal(f.calls.filter((c) => c.fn === "biometric_dat_chunk").length, 0);
});

test("upload: refusals at begin are returned as data (already imported, too large, empty)", async () => {
  const f = fakeServer({ refuseBegin: "already_imported" });
  assert.equal((await uploadDat(f.sb, { name: "x.dat", bytes: bytesOf(10) }, "dev", "Asia/Kolkata", { wait: noWait })).error, "already_imported");
  assert.equal((await uploadDat(f.sb, { name: "x.dat", bytes: new Uint8Array() }, "dev", "Asia/Kolkata")).error, "empty_file");
  assert.equal((await uploadDat(f.sb, { name: "x.dat", bytes: new Uint8Array(16777217) }, "dev", "Asia/Kolkata")).error, "file_too_large");
});

test("upload: 'Not allowed' is not retried", async () => {
  let n = 0;
  const sb: RpcClient = { rpc: () => { n++; return Promise.resolve({ data: null, error: { message: "Not allowed" } }); } };
  await assert.rejects(uploadDat(sb, { name: "x.dat", bytes: bytesOf(10) }, "dev", "Asia/Kolkata", { wait: noWait }), /Not allowed/);
  assert.equal(n, 1);
});

/* ------------------------------------------------------------------ fixtures and the real file */

test("synthetic fixtures are byte-exact as described in their README (sizes and hashes)", () => {
  const readme = readFileSync(join(FIX, "README.md"), "utf8");
  const files = readdirSync(FIX).filter((f) => f.endsWith(".dat"));
  assert.equal(files.length, 22);
  for (const f of files) {
    const b = readFileSync(join(FIX, f));
    const row = readme.split("\n").find((l) => l.includes("`" + f + "`"));
    assert.ok(row, `README lists ${f}`);
    const cells = row!.split("|").map((c) => c.trim());
    assert.equal(Number(cells[2]), b.length, `${f} size`);
    assert.equal(hex(b).slice(0, 16), cells[3], `${f} hash prefix`);
  }
});

test("synthetic fixtures contain no real data (2030 dates only; no device serial)", () => {
  for (const f of readdirSync(FIX).filter((x) => x.endsWith(".dat"))) {
    const t = readFileSync(join(FIX, f)).toString("latin1");
    assert.ok(!/2026-11-/.test(t), `${f} has no real-period dates`);
    // a device serial looks like four letters then nine digits; none may appear in a fixture or its name
    assert.ok(!/[A-Z]{4}\d{9}/i.test(t) && !/[A-Z]{4}\d{9}/i.test(f), `${f} has no device serial`);
  }
});

test("the real X2008 export is never in the repository", () => {
  const walk = (d: string): string[] => readdirSync(d, { withFileTypes: true }).flatMap((e) =>
    e.name === "node_modules" || e.name === ".git" || e.name === ".next" || e.name === "out" ? [] : e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]);
  const all = walk(join(__dirname, ".."));
  assert.ok(!all.some((p) => /attlog/i.test(p)), "no *attlog* file in the repository");
  const gi = readFileSync(join(__dirname, "..", ".gitignore"), "utf8");
  assert.ok(gi.includes("*_attlog*.dat"));
});

const REAL = process.env.ATTENDOS_REAL_DAT;
test("real X2008 export (local only): hash, size and six-field CRLF structure", { skip: !REAL || !existsSync(REAL) ? "ATTENDOS_REAL_DAT not set — real-file check SKIPPED (not passed)" : false }, () => {
  const b = readFileSync(REAL!);
  assert.equal(hex(b), "6f0115361bbb2f51c92c3424b3edf14ea07fd68643dbfc96670a3d7122192476");
  assert.equal(b.length, 6191);
  const lines = b.toString("utf8").split("\r\n");
  assert.equal(lines.pop(), "");
  assert.equal(lines.length, 151);
  assert.ok(lines.every((l) => l.split("\t").length === 6 && l.split("\t")[0].length === 9));
});

/* ------------------------------------------------------------------ permission */

test("file import is an Admin capability; HR keeps code mapping", () => {
  const roles: Role[] = ["admin", "hr", "manager", "employee"];
  assert.deepEqual(roles.filter((r) => can(r, "importBiometricFiles")), ["admin"]);
  assert.deepEqual(roles.filter((r) => can(r, "mapBiometricCodes")), ["admin", "hr"]);
});
