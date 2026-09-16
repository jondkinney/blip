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
export {
  removeRecipient,
  recipient,
  conversationTitle,
  addRecipient,
  MAX_RECIPIENTS
};
