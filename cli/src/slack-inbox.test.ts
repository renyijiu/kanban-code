import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, readdirSync, mkdirSync, writeFileSync, utimesSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  downloadSlackFile,
  formatPromptWithAttachments,
  sanitizeAttachmentName,
  sweepInbox,
} from "./slack/inbox.js";
import type { SlackFile } from "./slack/inbound.js";

const root = () => mkdtempSync(join(tmpdir(), "slack-inbox-"));

describe("sanitizeAttachmentName", () => {
  test("strips path separators and NUL bytes", () => {
    // path separators replaced; the dots are harmless without a separator.
    assert.equal(sanitizeAttachmentName("../../etc/passwd"), ".._.._etc_passwd");
    assert.equal(sanitizeAttachmentName("a/b\\c"), "a_b_c");
    assert.equal(sanitizeAttachmentName("foo\x00bar"), "foo_bar");
  });
  test("falls back when the name is missing or all-separators", () => {
    assert.equal(sanitizeAttachmentName(undefined), "attachment.bin");
    assert.equal(sanitizeAttachmentName(""), "attachment.bin");
    assert.equal(sanitizeAttachmentName("."), "attachment.bin");
    assert.equal(sanitizeAttachmentName(".."), "attachment.bin");
  });
  test("preserves a normal filename and caps very long names", () => {
    assert.equal(sanitizeAttachmentName("screenshot.png"), "screenshot.png");
    const long = "a".repeat(200) + ".pdf";
    assert.equal(sanitizeAttachmentName(long).length, 120);
  });
});

describe("downloadSlackFile", () => {
  test("downloads with Authorization: Bearer, writes a timestamped file under the agent inbox", async () => {
    let seenAuth: string | undefined;
    const fetchImpl = (async (_url: string, init?: any) => {
      seenAuth = init?.headers?.Authorization;
      return new Response(new Uint8Array([1, 2, 3, 4]), { status: 200 });
    }) as unknown as typeof fetch;
    const rootDir = root();
    const file: SlackFile = { id: "F1", name: "shot.png", mimetype: "image/png", url_private: "https://files.slack.com/F1" };
    const out = await downloadSlackFile(file, { botToken: "xoxb-test", slug: "scout", fetchImpl, rootDir, nowMs: Date.parse("2026-05-30T11:22:33.456Z") });
    assert.equal(seenAuth, "Bearer xoxb-test");
    assert.equal(out.name, "shot.png");
    assert.equal(out.size, 4);
    assert.match(out.path, /\/scout\/2026-05-30T11-22-33-456Z-shot\.png$/);
    assert.deepEqual([...readFileSync(out.path)], [1, 2, 3, 4]);
    assert.deepEqual(readdirSync(join(rootDir, "scout")).length, 1);
  });

  test("prefers url_private_download over url_private when both are present", async () => {
    let calledUrl = "";
    const fetchImpl = (async (url: string) => {
      calledUrl = url;
      return new Response(new Uint8Array(), { status: 200 });
    }) as unknown as typeof fetch;
    const file: SlackFile = { name: "x.bin", url_private: "https://A", url_private_download: "https://B" };
    await downloadSlackFile(file, { botToken: "t", slug: "s", fetchImpl, rootDir: root() });
    assert.equal(calledUrl, "https://B");
  });

  test("throws on HTTP error so the caller can log per-file failure", async () => {
    const fetchImpl = (async () => new Response("nope", { status: 403 })) as unknown as typeof fetch;
    const file: SlackFile = { name: "x.bin", url_private: "https://X" };
    await assert.rejects(
      () => downloadSlackFile(file, { botToken: "t", slug: "s", fetchImpl, rootDir: root() }),
      /HTTP 403/
    );
  });

  test("throws when the file exceeds maxBytes, without writing it", async () => {
    const fetchImpl = (async () => new Response(new Uint8Array(10), { status: 200 })) as unknown as typeof fetch;
    const file: SlackFile = { name: "big.bin", url_private: "https://X" };
    const rootDir = root();
    await assert.rejects(
      () => downloadSlackFile(file, { botToken: "t", slug: "s", fetchImpl, rootDir, maxBytes: 4 }),
      /exceeded max size/
    );
    // Directory may or may not exist depending on order, but no file should have been written.
    const dir = join(rootDir, "s");
    const files = (() => { try { return readdirSync(dir); } catch { return []; } })();
    assert.deepEqual(files, []);
  });

  test("rejects when the file has no url at all", async () => {
    await assert.rejects(
      () => downloadSlackFile({ name: "x" }, { botToken: "t", slug: "s", rootDir: root() }),
      /missing url_private/
    );
  });
});

describe("sweepInbox", () => {
  const seed = (rootDir: string, slug: string, name: string, ageMs: number) => {
    const dir = join(rootDir, slug);
    mkdirSync(dir, { recursive: true });
    const path = join(dir, name);
    writeFileSync(path, "x");
    const mtime = (Date.now() - ageMs) / 1000;
    utimesSync(path, mtime, mtime);
    return path;
  };

  test("removes files older than the retention window, keeps fresh ones", () => {
    const rootDir = root();
    const oldPath = seed(rootDir, "scout", "old.png", 10 * 24 * 60 * 60 * 1000);
    const newPath = seed(rootDir, "scout", "new.png", 1 * 60 * 1000);
    const out = sweepInbox({ rootDir, retentionDays: 7 });
    assert.equal(out.removedFiles, 1);
    assert.equal(out.removedDirs, 0);
    assert.equal(existsSync(oldPath), false);
    assert.equal(existsSync(newPath), true);
  });

  test("removes the per-agent dir once it becomes empty", () => {
    const rootDir = root();
    seed(rootDir, "scout", "old1.png", 10 * 24 * 60 * 60 * 1000);
    seed(rootDir, "scout", "old2.png", 10 * 24 * 60 * 60 * 1000);
    const out = sweepInbox({ rootDir, retentionDays: 7 });
    assert.equal(out.removedFiles, 2);
    assert.equal(out.removedDirs, 1);
    assert.equal(existsSync(join(rootDir, "scout")), false);
  });

  test("retentionDays <= 0 disables sweep (admin override)", () => {
    const rootDir = root();
    const oldPath = seed(rootDir, "scout", "old.png", 10 * 24 * 60 * 60 * 1000);
    assert.deepEqual(sweepInbox({ rootDir, retentionDays: 0 }), { removedFiles: 0, removedDirs: 0 });
    assert.equal(existsSync(oldPath), true);
  });

  test("missing root is a no-op (fresh box, no attachments ever)", () => {
    const out = sweepInbox({ rootDir: join(root(), "does-not-exist"), retentionDays: 7 });
    assert.deepEqual(out, { removedFiles: 0, removedDirs: 0 });
  });
});

describe("formatPromptWithAttachments", () => {
  test("returns just the text when no files were downloaded", () => {
    assert.equal(formatPromptWithAttachments("look at this", []), "look at this");
  });
  test("appends each attachment path on its own [attachment:] line", () => {
    const out = formatPromptWithAttachments("review", [
      { path: "/inbox/a.png", name: "a.png", size: 1 },
      { path: "/inbox/b.pdf", name: "b.pdf", size: 1 },
    ]);
    assert.equal(out, "review\n\n[attachment: /inbox/a.png]\n[attachment: /inbox/b.pdf]");
  });
  test("attachments-only message (no text) still produces a usable prompt", () => {
    const out = formatPromptWithAttachments("", [{ path: "/inbox/a.zip", name: "a.zip", size: 1 }]);
    assert.equal(out, "[attachment: /inbox/a.zip]");
  });
});
