import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// The renderer moved from Panel.qml into BlipView.qml in 1.8.0 (shared with the app window).
const panel = readFileSync(new URL("./BlipView.qml", import.meta.url), "utf8");
const widget = readFileSync(new URL("./BarWidget.qml", import.meta.url), "utf8");
const identitySettings = readFileSync(new URL("./IdentitySettings.qml", import.meta.url), "utf8");
const contactCompare = readFileSync(new URL("./ContactCardCompare.qml", import.meta.url), "utf8");
const settings = readFileSync(new URL("./BlipSettings.qml", import.meta.url), "utf8");
const identities = readFileSync(new URL("./BlipIdentities.qml", import.meta.url), "utf8");
const preferences = readFileSync(new URL("./BlipPreferences.qml", import.meta.url), "utf8");

describe("QML safety invariants", () => {
  test("group sends use the cached AppleScript GUID", () => {
    expect(panel).toContain('["--chat-id", String(root.active.guid)]');
    expect(panel).toContain('["--to", sendChat]');
  });

  test("thread results are accepted only for the active chat", () => {
    expect(panel).toContain('String(root.active.chat) === root.threadRunningChat');
    expect(panel).toContain("if (!belongsHere) return");
  });

  test("the compose field is never disabled by an in-flight send", () => {
    // Disabling the exclusive-keyboard-focus holder dismisses the panel the
    // instant Enter is pressed — the send works but all feedback vanishes.
    expect(panel).not.toContain("!sendProc.running");
  });

  test("send completion owns immutable chat and draft context", () => {
    expect(panel).toContain("var completedChat = root.sendChat");
    expect(panel).toContain("if (composeField.text === completedText) composeField.text = \"\"");
  });

  test("message text leaves this machine on stdin, never in argv (audit #4)", () => {
    expect(panel).toContain('"--text-stdin"');
    expect(panel).toContain("sendProc.write(text)");
    expect(panel).not.toContain('["--yes", "--", text]');
  });

  test("read marks are queued and only applied after a successful load", () => {
    expect(widget).toContain("property var refreshQueue: []");
    expect(widget).not.toContain("property var queued: null");
    const success = panel.indexOf("if (d.ok === true)");
    const mark = panel.indexOf("markThreadRead(root.threadRunningChat)");
    expect(success).toBeGreaterThan(-1);
    expect(mark).toBeGreaterThan(success);
  });

  test("identity repair separates harmless selection, Blip writes, and Mac review", () => {
    expect(identitySettings).toContain("Selecting a row below changes nothing");
    expect(identitySettings).toContain("Save “" + "\" + root.selectedCandidate.name");
    expect(identitySettings).toContain(" in Blip only");
    expect(identitySettings).toContain("MAC CONTACTS · OPTIONAL");
    expect(identitySettings).toContain("Opening a card makes no change");
    expect(identitySettings).toContain("Check Mac Contacts again");
    expect(identitySettings).toContain("is already saved in Blip");
    expect(identitySettings).toContain("No save is needed");
    expect(identitySettings).toContain("Nothing has changed yet");
    expect(identitySettings).toContain("as the Blip display name");
    expect(identitySettings).not.toContain("Already saved in Blip\"");
    expect(identitySettings).not.toContain('label: "Use"');
    expect(identitySettings).not.toContain("Fix on Mac");
  });

  test("settings navigation keeps contact repair compact and separate from appearance", () => {
    expect(settings).toContain('property string page: "contacts"');
    expect(settings).toContain('visible: root.page === "contacts"');
    expect(settings).toContain('visible: root.page === "appearance"');
    expect(settings).toContain("width: Math.min(parent.width, root.space(1120))");
    expect(identitySettings).toContain('label: "← All conversations"');
    expect(identitySettings).toContain("visible: !root.reviewActive");
    expect(identitySettings).toContain("visible: root.macReviewExpanded");
    expect(identitySettings).toContain("Review Contacts cards…");
    expect(identitySettings).toContain("sourceCandidate.cardsExpanded ? sourceCandidate.modelData.cards : []");
    expect(identitySettings).toContain("root.candidateForToken(saved.contactToken)");
  });

  test("silent settings refreshes preserve stable models and visible state", () => {
    expect(identities).toContain("loading = quiet !== true");
    expect(identities).toContain("if (serialized !== identitiesJson)");
    expect(identities).toContain("pendingReviewHandle = requested");
    expect(identities).toContain('if (!worker.running && root.activeHandle === "") root.load(true)');
    expect(preferences).toContain("if (loaded && serialized === lastSerialized) return true");
  });

  test("Mac contact writes require preview, confirmation, and expose undo", () => {
    expect(identitySettings).toContain('label: "Remove this handle…"');
    expect(identitySettings).toContain('label: "Remove from Mac Contacts"');
    expect(identitySettings).toContain("An undo receipt will be saved on the Mac");
    expect(identitySettings).toContain('label: "Undo Mac change"');
    expect(identities).toContain("function inspectOnMac(handle, token, ownerToken)");
    expect(identities).toContain("function removeOnMac()");
    expect(identities).toContain("function undoOnMac()");
    expect(identities).toContain("repairPreview.writeEnabled");
    expect(identities).toContain("validToken(repairPreview.ownerToken)");
  });

  test("contact comparison is local and linking has a separate upstream confirmation", () => {
    expect(identitySettings).toContain("Compare & link ");
    expect(identitySettings).toContain("active Contacts cards…");
    expect(identitySettings).toContain("ContactCardCompare");
    expect(contactCompare).toContain('title: "Compare"');
    expect(contactCompare).toContain("DIFFERENCES ONLY");
    expect(contactCompare).toContain("sharedRowMap");
    expect(contactCompare).toContain("MERGED PREVIEW");
    expect(contactCompare).toContain("Prepare link in Contacts…");
    expect(contactCompare).toContain("CONFIRM AN UPSTREAM CONTACTS CHANGE");
    expect(contactCompare).toContain("Checking makes no changes");
    expect(contactCompare).toContain("Open & edit on Mac…");
    expect(contactCompare).toContain("Text.PlainText");
    expect(contactCompare).not.toContain("Array.isArray(card.phones)");
    expect(identities).toContain("function compareCards(handle, ownerToken)");
    expect(identities).toContain("function prepareLink()");
    expect(identities).toContain("function linkCards()");
    expect(identities).toContain("linkPreview.ready");
    expect(identities).toContain("expectedAction: linkPreview.action");
  });
});
