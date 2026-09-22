#!/usr/bin/env bun
/** First group message: bounded stdin in both directions, never a body in argv. */
import { spawnSync } from "node:child_process";
import { readStdinBounded } from "./contact-review";
import { recipient, MAX_RECIPIENTS, createdGroup } from "./new-conversation";
import { bridgeFor } from "./shim-path";
export const MAX_GROUP_REQUEST = 48 * 1024;
export const MAX_GROUP_RESPONSE = 4096;
export function groupRequest(value: unknown): { recipients: string[]; text: string } {
  if (!value || typeof value !== "object") throw new Error("Invalid group request");
  const d = value as Record<string, unknown>;
  if (!Array.isArray(d.recipients) || d.recipients.length < 2 || d.recipients.length > MAX_RECIPIENTS)
    throw new Error("Choose between 2 and 31 recipients");
  const handles = d.recipients.map(handle => recipient({ handle })?.handle);
  if (handles.some(h => !h) || new Set(handles).size !== handles.length) throw new Error("Invalid or duplicate recipients");
  if (typeof d.text !== "string" || !d.text.trim() || d.text.length > 4000 || d.text.includes("\0"))
    throw new Error("Write a message of at most 4000 characters");
  return { recipients: handles as string[], text: d.text.trim() };
}
export function sendGroup(value: unknown, runner = spawnSync, home?: string) {
  const request = groupRequest(value);
  const input = JSON.stringify(request);
  if (Buffer.byteLength(input) > MAX_GROUP_REQUEST) throw new Error("Group request is too large");
  // There is no conversation ID until the Mac confirms the first send.
  const bridge = bridgeFor("", "imsg-send", home);
  const result = runner(bridge.cmd, [...bridge.args, "--new-group-stdin", "--yes"],
    { input, encoding: "utf8", timeout: 330000, maxBuffer: MAX_GROUP_RESPONSE });
  const fail = (error: string, uncertain = false) => ({ ok: false, error, uncertain });
  if (result.status === 69) return fail("Mac unreachable");
  if (result.error || result.signal || result.status === 255)
    return fail("Connection interrupted. Check Messages on the Mac before trying again.", true);
  let data: any;
  try { data = JSON.parse(String(result.stdout || "")); } catch {
    return fail(result.status === 2 ? "Update the Mac bridge to support new groups" : "Invalid Mac response. Check Messages before trying again.", result.status !== 2);
  }
  const group = createdGroup(data);
  if (result.status === 0 && group) return { ok: true, ...group };
  // Only the new protocol's bounded, sanitized error leaves the helper. Never
  // forward stderr: an AppleScript runtime error can quote its source/body.
  const error = typeof data?.error === "string" ? data.error.slice(0, 240).replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, " ") : "Could not create the group";
  return fail(error, data?.uncertain !== false);
}
if (import.meta.main) {
  try { console.log(JSON.stringify(sendGroup(JSON.parse(await readStdinBounded(process.stdin as any, MAX_GROUP_REQUEST))))); }
  catch { console.log(JSON.stringify({ ok: false, error: "Invalid new-group request", uncertain: false })); }
}
