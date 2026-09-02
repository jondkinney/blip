import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyIdentityOverrides, applyThreadIdentityOverrides, type Thread } from "./collector";
import {
  contactWritesEnabled,
  contactMutationOnMac,
  identityKey,
  identityNameFor,
  MAX_BRIDGE_CONFIG_BYTES,
  MAX_IDENTITIES_BYTES,
  MAX_IDENTITY_REQUEST_BYTES,
  normalizeBridgeCandidates,
  normalizeContactComparison,
  normalizeContactDraft,
  normalizeIdentityConfig,
  normalizeRepairPreview,
  parseIdentities,
  readBoundedIdentityFile,
  readBoundedBridgeConfig,
  readIdentities,
  resolveOnMac,
  safeReadIdentityConfig,
  writeIdentities,
  type IdentityConfig,
} from "./identities";

const roots: string[] = [];
function fixture(): { root: string; path: string } {
  const root = mkdtempSync(join(tmpdir(), "blip-identities-"));
  roots.push(root);
  return { root, path: join(root, "blip", "identities.json") };
}
afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

const token = "sha256:" + "a".repeat(64);
const cardToken = (character: string) => "sha256:" + character.repeat(64);
const config: IdentityConfig = {
  schemaVersion: 1,
  identities: {
    "+15550100001": { name: "Alex Rivera", source: "contacts", contactToken: token },
    "quiet@example.com": { name: "Quiet Person", source: "custom" },
  },
};

describe("identity schema", () => {
  test("normalizes valid contact and custom choices", () => {
    expect(normalizeIdentityConfig(config)).toEqual(config);
  });

  test("phone variants and email case share one identity key", () => {
    expect(identityKey("+1 (555) 010-0001")).toBe(identityKey("5550100001"));
    expect(identityKey("QUIET@EXAMPLE.COM")).toBe(identityKey("quiet@example.com"));
    expect(identityNameFor("5550100001", config)).toBe("Alex Rivera");
  });

  test("rejects wrong top-level types, versions, sources, and tokens", () => {
    for (const value of [null, [], "x", 1, true])
      expect(() => normalizeIdentityConfig(value)).toThrow("JSON object");
    expect(() => normalizeIdentityConfig({ ...config, schemaVersion: 2 })).toThrow("schemaVersion");
    expect(() => normalizeIdentityConfig({ schemaVersion: 1, identities: {
      "+15550100001": { name: "Alex", source: "guessed" },
    } })).toThrow("source");
    expect(() => normalizeIdentityConfig({ schemaVersion: 1, identities: {
      "+15550100001": { name: "Alex", source: "contacts", contactToken: "bad" },
    } })).toThrow("token");
  });

  test("rejects equivalent duplicate handles", () => {
    expect(() => normalizeIdentityConfig({ schemaVersion: 1, identities: {
      "+1 (555) 010-0001": { name: "Alex", source: "custom" },
      "5550100001": { name: "Someone else", source: "custom" },
    } })).toThrow("equivalent duplicate");
  });

  test("caps before sanitizing and strips dangerous display controls", () => {
    const normalized = normalizeIdentityConfig({ schemaVersion: 1, identities: {
      "+15550100001": { name: "Alex\u202e HTML <b>x</b>", source: "custom" },
    } });
    expect(normalized.identities["+15550100001"]!.name).toBe("Alex HTML <b>x</b>");
    expect(() => normalizeIdentityConfig({ schemaVersion: 1, identities: {
      "+15550100001": { name: "x".repeat(161), source: "custom" },
    } })).toThrow("too long");
  });

  test("malformed JSON is reported without echoing content", () => {
    expect(() => parseIdentities('{"private":"do not echo"')).toThrow("not valid JSON");
  });
});

describe("bounded identity file", () => {
  test("a missing file is an empty config", () => {
    const { path } = fixture();
    expect(readIdentities(path)).toEqual({ exists: false, config: { schemaVersion: 1, identities: {} } });
  });

  test("round-trips atomically with private modes", () => {
    const { root, path } = fixture();
    writeIdentities(path, config);
    expect(readIdentities(path)).toEqual({ exists: true, config });
    expect(lstatSync(join(root, "blip")).mode & 0o777).toBe(0o700);
    expect(lstatSync(path).mode & 0o777).toBe(0o600);
    expect(readFileSync(path, "utf8")).toContain('"Alex Rivera"');
  });

  test("accepts the exact byte cap and rejects one byte over", () => {
    const { path } = fixture();
    writeIdentities(path, config);
    writeFileSync(path, Buffer.alloc(MAX_IDENTITIES_BYTES, 0x20));
    expect(readBoundedIdentityFile(path)?.length).toBe(MAX_IDENTITIES_BYTES);
    writeFileSync(path, Buffer.alloc(MAX_IDENTITIES_BYTES + 1, 0x20));
    expect(() => readBoundedIdentityFile(path)).toThrow("too large");
  });

  test("rejects symlinks and nonblocking FIFOs", () => {
    const first = fixture();
    const target = join(first.root, "target.json");
    writeIdentities(target, config);
    writeIdentities(join(first.root, "blip", "seed.json"), config);
    symlinkSync(target, first.path);
    expect(() => readBoundedIdentityFile(first.path)).toThrow();
    expect(() => writeIdentities(first.path, config)).toThrow("regular file");

    const second = fixture();
    writeIdentities(join(second.root, "blip", "seed.json"), config);
    expect(Bun.spawnSync(["mkfifo", second.path]).exitCode).toBe(0);
    expect(() => readBoundedIdentityFile(second.path)).toThrow("regular file");
  });

  test("tightens a permissive identity directory and fails closed on invalid config", () => {
    const { root, path } = fixture();
    writeIdentities(path, config);
    chmodSync(join(root, "blip"), 0o755);
    writeIdentities(path, config);
    expect(lstatSync(join(root, "blip")).mode & 0o777).toBe(0o700);
    writeFileSync(path, "not json");
    expect(safeReadIdentityConfig(path)).toEqual({ schemaVersion: 1, identities: {} });
  });
});

describe("contact-write opt-in", () => {
  test("is disabled by default and accepts only an explicit on value", () => {
    const { root } = fixture();
    const path = join(root, "blip", "bridge.conf");
    writeIdentities(join(root, "blip", "seed.json"), config);
    writeFileSync(path, "host=mac\ncontact_writes=off\n");
    expect(contactWritesEnabled(path)).toBe(false);
    writeFileSync(path, "contact_writes='on'\n");
    expect(contactWritesEnabled(path)).toBe(true);
    writeFileSync(path, "contact_writes=on\ncontact_writes=off\n");
    expect(contactWritesEnabled(path)).toBe(false);
  });

  test("fails closed for oversized, symlinked, and group-writable config", () => {
    const first = fixture();
    const path = join(first.root, "blip", "bridge.conf");
    writeIdentities(join(first.root, "blip", "seed.json"), config);
    writeFileSync(path, Buffer.alloc(MAX_BRIDGE_CONFIG_BYTES + 1, 0x20));
    expect(contactWritesEnabled(path)).toBe(false);
    expect(() => readBoundedBridgeConfig(path)).toThrow("too large");
    writeFileSync(path, "contact_writes=on\n");
    chmodSync(path, 0o622);
    expect(contactWritesEnabled(path)).toBe(false);

    const second = fixture();
    const target = join(second.root, "target.conf");
    const link = join(second.root, "blip", "bridge.conf");
    writeIdentities(join(second.root, "blip", "seed.json"), config);
    writeFileSync(target, "contact_writes=on\n");
    symlinkSync(target, link);
    expect(contactWritesEnabled(link)).toBe(false);
  });
});

describe("Mac candidate boundary", () => {
  test("validates a bounded candidate response", () => {
    const cards = [
      { token: cardToken("b"), accountNumber: 1, sourceName: "iCloud", hasPhoto: true, matchCount: 1 },
      { token: cardToken("c"), accountNumber: 2, sourceName: "Google", hasPhoto: false, matchCount: 1 },
      { token: cardToken("d"), accountNumber: 2, sourceName: "Google", hasPhoto: false, matchCount: 1 },
    ];
    expect(normalizeBridgeCandidates({
      ok: true,
      handle: "+15550100001",
      candidates: [{
        token, name: "Alex Rivera", recordCount: 3, sourceCount: 2, hasPhoto: true, cards,
      }],
    }, "+15550100001")).toEqual([
      { token, name: "Alex Rivera", recordCount: 3, sourceCount: 2, hasPhoto: true, cards },
    ]);
  });

  test("rejects wrong handles, oversized lists, and hostile fields", () => {
    expect(() => normalizeBridgeCandidates({ ok: true, handle: "+15550100002", candidates: [] }, "+15550100001"))
      .toThrow("different handle");
    expect(() => normalizeBridgeCandidates({ ok: true, handle: "+15550100001", candidates: Array(9).fill({
      token, name: "Alex", recordCount: 1, sourceCount: 1, hasPhoto: false,
    }) }, "+15550100001")).toThrow("too many");
    expect(() => normalizeBridgeCandidates({ ok: true, handle: "+15550100001", candidates: [{
      token: "bad", name: "<b>unsafe</b>", recordCount: 1, sourceCount: 1, hasPhoto: false,
    }] }, "+15550100001")).toThrow("token");
    expect(() => normalizeBridgeCandidates({ ok: true, handle: "+15550100001", candidates: [{
      token, name: "Alex", recordCount: 2, sourceCount: 1, hasPhoto: false,
      cards: [{ token: cardToken("b"), accountNumber: 1, sourceName: "iCloud", hasPhoto: false }],
    }] }, "+15550100001")).toThrow("source-card list");
    expect(() => normalizeBridgeCandidates({ ok: true, handle: "+15550100001", candidates: [{
      token, name: "Alex", recordCount: 1, sourceCount: 2, hasPhoto: false,
      cards: [{ token: cardToken("b"), accountNumber: 1, sourceName: "iCloud", hasPhoto: false }],
    }] }, "+15550100001")).toThrow("account metadata");
  });

  test("the handle travels through stdin, never argv", () => {
    let capturedArgs: string[] = [];
    let capturedInput = "";
    const runner = ((_command: string, args: string[], options: any) => {
      capturedArgs = args;
      capturedInput = options.input;
      return {
        status: 0,
        signal: null,
        output: [],
        pid: 1,
        stdout: JSON.stringify({
          ok: true,
          handle: "+15550100001",
          candidates: [{
            token, name: "Alex Rivera", recordCount: 1, sourceCount: 1, hasPhoto: false,
            cards: [{ token: cardToken("b"), accountNumber: 1, sourceName: "iCloud", hasPhoto: false }],
          }],
        }),
        stderr: "",
        error: undefined,
      };
    }) as any;
    const result = resolveOnMac("candidates", "+15550100001", undefined, runner);
    expect(capturedArgs).toEqual(["--json", "resolve"]);
    expect(capturedArgs.join(" ")).not.toContain("15550100001");
    expect(JSON.parse(capturedInput).handle).toBe("+15550100001");
    expect(result.candidates?.[0]?.name).toBe("Alex Rivera");
  });

  test("exact-card open keeps its token on stdin and validates card metadata", () => {
    let capturedInput = "";
    const exactToken = cardToken("e");
    const runner = ((_command: string, args: string[], options: any) => {
      capturedInput = options.input;
      return {
        status: 0,
        signal: null,
        output: [],
        pid: 1,
        stdout: JSON.stringify({
          ok: true, opened: true, name: "Alex Rivera",
          cardNumber: 2, cardCount: 3, accountNumber: 1, sourceName: "iCloud",
        }),
        stderr: "",
        error: undefined,
      };
    }) as any;
    expect(resolveOnMac("open", "+15550100001", exactToken, runner)).toEqual({
      handle: "+15550100001", opened: true, name: "Alex Rivera",
      cardNumber: 2, cardCount: 3, accountNumber: 1, sourceName: "iCloud",
    });
    expect(JSON.parse(capturedInput)).toEqual({
      operation: "open", handle: "+15550100001", token: exactToken,
    });
  });

  test("validates repair previews and rejects inconsistent metadata", () => {
    const preview = {
      handle: "+15550100001", name: "Pat Rivera", kind: "phone",
      fieldCount: 1, labels: ["mobile"], cardNumber: 1, cardCount: 2,
      accountNumber: 1, sourceName: "iCloud", writeEnabled: true,
    };
    expect(normalizeRepairPreview(preview, "5550100001")).toEqual(preview);
    expect(() => normalizeRepairPreview({ ...preview, labels: [] }, preview.handle))
      .toThrow("field-label");
    expect(() => normalizeRepairPreview({ ...preview, cardNumber: 3 }, preview.handle))
      .toThrow("inconsistent card");
    expect(() => normalizeRepairPreview({ ...preview, name: "x".repeat(161) }, preview.handle))
      .toThrow("too long");
  });

  test("validates bounded contact-card comparisons", () => {
    const comparison = {
      handle: "+15550100001", name: "Alex Rivera", cardCount: 2,
      sourceCount: 2, writeEnabled: true,
      cards: [1, 2].map((number) => ({
        token: cardToken(number === 1 ? "b" : "c"), revision: cardToken(number === 1 ? "d" : "e"), cardNumber: number,
        accountNumber: number, sourceName: number === 1 ? "iCloud" : "Google",
        hasPhoto: number === 1,
        displayName: "Alex Rivera", firstName: "Alex", middleName: "", lastName: "Rivera",
        nickname: "", organization: "Example", department: "", jobTitle: "",
        birthday: "--09-02", note: "",
        phones: [{ label: "mobile", value: "+1 555 010 0001" }],
        emails: number === 1 ? [{ label: "home", value: "alex@example.com" }] : [],
        urls: [], addresses: number === 2 ? [{ label: "home", street: "1 Main St",
          city: "Madison", state: "WI", postalCode: "53703", country: "US",
          countryCode: "US" }] : [],
      })),
    };
    expect(normalizeContactComparison(comparison, "5550100001")).toEqual(comparison);
    expect(() => normalizeContactComparison({ ...comparison, cards: [
      comparison.cards[0], { ...comparison.cards[1], token: comparison.cards[0]!.token },
    ] }, comparison.handle)).toThrow("duplicate comparison card");
    expect(() => normalizeContactComparison({ ...comparison, cards: [
      comparison.cards[0], { ...comparison.cards[1], cardNumber: 3 },
    ] }, comparison.handle)).toThrow("card numbers");
    expect(() => normalizeContactComparison({ ...comparison, cards: [
      { ...comparison.cards[0], phones: Array(17).fill({ label: "x", value: "1" }) },
      comparison.cards[1],
    ] }, comparison.handle)).toThrow("phone list");
    expect(() => normalizeContactComparison({ ...comparison, cards: [
      { ...comparison.cards[0], note: "x".repeat(1001) }, comparison.cards[1],
    ] }, comparison.handle)).toThrow("note");
  });

  test("comparison and link operations stay on stdin and validate Apple actions", () => {
    const comparison = {
      handle: "+15550100001", name: "Alex Rivera", cardCount: 2,
      sourceCount: 2, writeEnabled: true,
      cards: [1, 2].map((number) => ({
        token: cardToken(number === 1 ? "b" : "c"), revision: cardToken(number === 1 ? "d" : "e"), cardNumber: number,
        accountNumber: number, sourceName: number === 1 ? "iCloud" : "Google",
        hasPhoto: false, displayName: "Alex Rivera",
        firstName: "Alex", middleName: "", lastName: "Rivera", nickname: "",
        organization: "", department: "", jobTitle: "", birthday: "", note: "",
        phones: [], emails: [], urls: [], addresses: [],
      })),
    };
    const captured: Array<{ args: string[]; input: string }> = [];
    const responses = [
      { ok: true, ...comparison },
      { ok: true, handle: comparison.handle, name: comparison.name, cardCount: 2,
        sourceCount: 2, writeEnabled: true, ready: true, action: "Link Selected Cards" },
      { ok: true, handle: comparison.handle, name: comparison.name, cardCount: 2,
        sourceCount: 2, writeEnabled: true, linked: true, action: "Link Selected Cards" },
    ];
    const runner = ((_command: string, args: string[], options: any) => {
      captured.push({ args, input: options.input });
      return { status: 0, signal: null, output: [], pid: 1,
        stdout: JSON.stringify(responses.shift()), stderr: "", error: undefined };
    }) as any;
    expect(resolveOnMac("compare", comparison.handle, token, runner).comparison?.cardCount).toBe(2);
    expect(resolveOnMac("link-prepare", comparison.handle, token, runner).linkPreview?.ready).toBe(true);
    expect(resolveOnMac(
      "link", comparison.handle, token, runner, undefined, "Link Selected Cards",
    ).linkResult?.linked).toBe(true);
    expect(captured.every(({ args }) => args.join(" ").includes("15550100001") === false)).toBe(true);
    expect(captured.map(({ input }) => JSON.parse(input))).toEqual([
      { operation: "compare", handle: comparison.handle, ownerToken: token },
      { operation: "link-prepare", handle: comparison.handle, ownerToken: token },
      { operation: "link", handle: comparison.handle, ownerToken: token,
        expectedAction: "Link Selected Cards" },
    ]);
    const badRunner = (() => ({ status: 0, signal: null, output: [], pid: 1,
      stdout: JSON.stringify({ ...responses[0], ok: true, handle: comparison.handle,
        name: comparison.name, cardCount: 2, sourceCount: 2, writeEnabled: true,
        ready: true, action: "Delete Cards" }), stderr: "", error: undefined })) as any;
    expect(() => resolveOnMac("link-prepare", comparison.handle, token, badRunner))
      .toThrow("invalid link action");
    expect(() => resolveOnMac(
      "link", comparison.handle, token, runner, undefined, "Delete Cards",
    )).toThrow("confirmed Contacts action");
  });

  test("contact edits are bounded, revision-pinned, previewed, and confirmed", () => {
    const exactToken = cardToken("b");
    const revision = cardToken("c");
    const planHash = cardToken("d");
    const draft = normalizeContactDraft({
      firstName: "Alex", middleName: "", lastName: "Rivera", nickname: "Lex",
      organization: "Example", department: "", jobTitle: "", birthday: "--09-02",
      note: "", phones: [{ label: "mobile", value: "+1 555 010 0001" }],
      emails: [], urls: [], addresses: [],
    });
    const metadata = {
      action: "edit", handle: "+15550100001", name: "Alex Rivera", cardNumber: 1,
      cardCount: 2, accountNumber: 1, sourceName: "iCloud", sourceCardCount: 0,
      changedFields: ["nickname"], planHash, writeEnabled: true,
    };
    const captured: string[] = [];
    const responses = [
      { ok: true, preview: metadata },
      { ok: true, ...metadata, applied: true, undoToken: "undo:" + "f".repeat(32),
        revision: cardToken("e"), displayName: "Alex Rivera" },
    ];
    const runner = ((_command: string, args: string[], options: any) => {
      expect(args).toEqual(["--json", "resolve"]);
      captured.push(options.input);
      return { status: 0, signal: null, output: [], pid: 1,
        stdout: JSON.stringify(responses.shift()), stderr: "", error: undefined };
    }) as any;
    const input = { handle: metadata.handle, ownerToken: token, token: exactToken, revision, card: draft };
    expect(contactMutationOnMac("edit-prepare", input, runner).preview?.action).toBe("edit");
    expect(contactMutationOnMac("edit", { ...input, planHash }, runner).result?.applied).toBe(true);
    expect(JSON.parse(captured[0]!)).toEqual({ operation: "edit-prepare", ...input });
    expect(JSON.parse(captured[1]!)).toEqual({ operation: "edit", ...input, planHash });
    expect(() => contactMutationOnMac("edit", { ...input, planHash: "sha256:bad" }, runner))
      .toThrow("revision");
  });

  test("inspect, removal, and undo keep contact data on stdin and validate receipts", () => {
    const exactToken = cardToken("e");
    const undoToken = "undo:" + "f".repeat(32);
    const preview = {
      handle: "+15550100001", name: "Pat Rivera", kind: "phone",
      fieldCount: 1, labels: ["mobile"], cardNumber: 1, cardCount: 2,
      accountNumber: 1, sourceName: "iCloud", writeEnabled: true,
    };
    const captured: Array<{ args: string[]; input: string }> = [];
    const responses = [
      { ok: true, preview },
      { ok: true, ...preview, removed: true, undoToken },
      { ok: true, restored: true, alreadyPresent: false, handle: preview.handle,
        name: preview.name, action: "field-removal", cardCount: 1, fieldCount: 1 },
    ];
    const runner = ((_command: string, args: string[], options: any) => {
      captured.push({ args, input: options.input });
      return { status: 0, signal: null, output: [], pid: 1,
        stdout: JSON.stringify(responses.shift()), stderr: "", error: undefined };
    }) as any;
    expect(resolveOnMac("inspect", preview.handle, exactToken, runner, token).preview).toEqual(preview);
    expect(resolveOnMac("remove", preview.handle, exactToken, runner, token).removal?.undoToken).toBe(undoToken);
    expect(resolveOnMac("undo", undefined, undoToken, runner).undo?.restored).toBe(true);
    expect(captured.every(({ args }) => args.join(" ").includes("15550100001") === false)).toBe(true);
    expect(JSON.parse(captured[0]!.input)).toEqual({
      operation: "inspect", handle: preview.handle, token: exactToken, ownerToken: token,
    });
    expect(JSON.parse(captured[2]!.input)).toEqual({ operation: "undo", undoToken });
    expect(() => resolveOnMac("undo", undefined, "undo:bad", runner)).toThrow("undo token");
  });
});

describe("collector identity application", () => {
  test("names messages and quiet DM rows without changing group titles", () => {
    const messages = applyIdentityOverrides([{
      ts: "2026-09-02 10:00:00", from_me: false, handle: "5550100001", name: null,
      service: "iMessage", chat: "+15550100001", text: "hello",
    }], config);
    expect(messages[0]!.name).toBe("Alex Rivera");

    const base: Thread = {
      chat: "+15550100001", guid: "", name: "+15550100001", handle: "+15550100001",
      service: "iMessage", last_ts: "", last_text: "", last_from_me: false, count: 0, unread: 0,
    };
    expect(applyThreadIdentityOverrides([base], config)[0]!.name).toBe("Alex Rivera");
    const group = { ...base, chat: "chat123", name: "Family", guid: "any;+;chat123" };
    expect(applyThreadIdentityOverrides([group], config)[0]!.name).toBe("Family");
  });
});

describe("identity CLI streaming boundary", () => {
  test("exits before an oversized producer closes stdin", async () => {
    const { path } = fixture();
    const child = Bun.spawn(["bun", join(import.meta.dir, "identities.ts"), "custom"], {
      env: { ...process.env, BLIP_IDENTITIES_PATH: path },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    child.stdin.write(Buffer.alloc(MAX_IDENTITY_REQUEST_BYTES + 1, 0x20));
    child.stdin.flush();
    const result = await Promise.race([
      child.exited.then((code) => ({ code })),
      Bun.sleep(1500).then(() => ({ code: -999 })),
    ]);
    expect(result.code).not.toBe(-999);
    expect(result.code).not.toBe(0);
    try { child.stdin.end(); } catch { /* child already closed the pipe */ }
  });
});
