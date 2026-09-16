// Recipient selection stays local until the user starts a conversation.
// bun build new-conversation.ts --target browser --format esm --outfile NewConversation.mjs
export interface Recipient { name: string; handle: string; kind?: string }
export const MAX_RECIPIENTS = 31;
const unsafe = /[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/;

export function recipient(value: unknown): Recipient | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.handle !== "string" || raw.handle.length > 254 || unsafe.test(raw.handle)) return null;
  const handle = raw.handle.trim().toLowerCase();
  if (!/^\+?[0-9]{3,15}$/.test(handle) && !/^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/.test(handle)) return null;
  const name = typeof raw.name === "string" ? raw.name.slice(0, 160).replace(new RegExp(unsafe.source, "g"), " ").trim() : "";
  return { handle, name: name || handle };
}

export function addRecipient(selected: Recipient[], hit: unknown): { recipients: Recipient[]; error: string } {
  const clean = recipient(hit);
  if (!clean) return { recipients: selected, error: "Choose a valid phone number or email address" };
  if (selected.some(p => p.handle.toLowerCase() === clean.handle))
    return { recipients: selected, error: "Already added" };
  if (selected.length >= MAX_RECIPIENTS)
    return { recipients: selected, error: `Choose at most ${MAX_RECIPIENTS} recipients` };
  return { recipients: selected.concat([clean]), error: "" };
}

export function removeRecipient(selected: Recipient[], handle: string): Recipient[] {
  return selected.filter(p => p.handle !== handle);
}

export function conversationTitle(selected: Recipient[]): string {
  return selected.map(p => p.name).join(" & ");
}

export function isDraftChat(chat: unknown): boolean {
  return typeof chat === "string" && /^new-group:[0-9-]{1,60}$/.test(chat);
}

export function groupDraft(selected: Recipient[], nonce: string) {
  const people = selected.map(recipient);
  if (!isDraftChat(`new-group:${nonce}`) || people.length < 2 || people.length > MAX_RECIPIENTS
      || people.some(p => !p) || new Set(people.map(p => p!.handle)).size !== people.length) return null;
  return { chat: `new-group:${nonce}`, guid: "", handle: "", name: conversationTitle(selected),
    recipients: people, participants: people, service: "iMessage", last_ts: "", last_text: "",
    last_from_me: false, count: 0, unread: 0 };
}

export function createdGroup(value: unknown): { chat: string; guid: string; service: string } | null {
  if (!value || typeof value !== "object") return null;
  const d = value as Record<string, unknown>;
  if (d.ok !== true || typeof d.guid !== "string" || d.guid.length > 100) return null;
  const parts = /^(iMessage|SMS|RCS|any);\+;(chat[0-9]{1,40}|[0-9a-fA-F]{32})$/.exec(d.guid);
  if (!parts || d.chat !== parts[2]) return null;
  return { chat: parts[2], guid: d.guid, service: parts[1] === "any" ? "iMessage" : parts[1] };
}

export function remapPending<T extends { chat: string }>(pending: T[], draftChat: string, chat: string): T[] {
  return pending.map(p => p.chat === draftChat ? Object.assign({}, p, { chat }) : p);
}
