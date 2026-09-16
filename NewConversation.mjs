// new-conversation.ts
var MAX_RECIPIENTS = 31;
var unsafe = /[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/;
function recipient(value) {
  if (!value || typeof value !== "object")
    return null;
  const raw = value;
  if (typeof raw.handle !== "string" || raw.handle.length > 254 || unsafe.test(raw.handle))
    return null;
  const handle = raw.handle.trim().toLowerCase();
  if (!/^\+?[0-9]{3,15}$/.test(handle) && !/^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/.test(handle))
    return null;
  const name = typeof raw.name === "string" ? raw.name.slice(0, 160).replace(new RegExp(unsafe.source, "g"), " ").trim() : "";
  return { handle, name: name || handle };
}
function addRecipient(selected, hit) {
  const clean = recipient(hit);
  if (!clean)
    return { recipients: selected, error: "Choose a valid phone number or email address" };
  if (selected.some((p) => p.handle.toLowerCase() === clean.handle))
    return { recipients: selected, error: "Already added" };
  if (selected.length >= MAX_RECIPIENTS)
    return { recipients: selected, error: `Choose at most ${MAX_RECIPIENTS} recipients` };
  return { recipients: selected.concat([clean]), error: "" };
}
function removeRecipient(selected, handle) {
  return selected.filter((p) => p.handle !== handle);
}
function conversationTitle(selected) {
  return selected.map((p) => p.name).join(" & ");
}
function isDraftChat(chat) {
  return typeof chat === "string" && /^new-group:[0-9-]{1,60}$/.test(chat);
}
function groupDraft(selected, nonce) {
  const people = selected.map(recipient);
  if (!isDraftChat(`new-group:${nonce}`) || people.length < 2 || people.length > MAX_RECIPIENTS || people.some((p) => !p) || new Set(people.map((p) => p.handle)).size !== people.length)
    return null;
  return {
    chat: `new-group:${nonce}`,
    guid: "",
    handle: "",
    name: conversationTitle(selected),
    recipients: people,
    participants: people,
    service: "iMessage",
    last_ts: "",
    last_text: "",
    last_from_me: false,
    count: 0,
    unread: 0
  };
}
function createdGroup(value) {
  if (!value || typeof value !== "object")
    return null;
  const d = value;
  if (d.ok !== true || typeof d.guid !== "string" || d.guid.length > 100)
    return null;
  const parts = /^(iMessage|SMS|RCS|any);\+;(chat[0-9]{1,40}|[0-9a-fA-F]{32})$/.exec(d.guid);
  if (!parts || d.chat !== parts[2])
    return null;
  return { chat: parts[2], guid: d.guid, service: parts[1] === "any" ? "iMessage" : parts[1] };
}
function remapPending(pending, draftChat, chat) {
  return pending.map((p) => p.chat === draftChat ? Object.assign({}, p, { chat }) : p);
}
export {
  removeRecipient,
  remapPending,
  recipient,
  isDraftChat,
  groupDraft,
  createdGroup,
  conversationTitle,
  addRecipient,
  MAX_RECIPIENTS
};
