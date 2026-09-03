import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// The renderer moved from Panel.qml into BlipView.qml in 1.8.0 (shared with the app window).
const panel = readFileSync(new URL("./BlipView.qml", import.meta.url), "utf8");
const widget = readFileSync(new URL("./BarWidget.qml", import.meta.url), "utf8");
const identitySettings = readFileSync(new URL("./IdentitySettings.qml", import.meta.url), "utf8");
const contactCompare = readFileSync(new URL("./ContactCardCompare.qml", import.meta.url), "utf8");
const contactEditor = readFileSync(new URL("./ContactCardEditor.qml", import.meta.url), "utf8");
const settings = readFileSync(new URL("./BlipSettings.qml", import.meta.url), "utf8");
const identities = readFileSync(new URL("./BlipIdentities.qml", import.meta.url), "utf8");
const identityHelper = readFileSync(new URL("./identities.ts", import.meta.url), "utf8");
const preferences = readFileSync(new URL("./BlipPreferences.qml", import.meta.url), "utf8");
const window = readFileSync(new URL("./BlipWindow.qml", import.meta.url), "utf8");

function handleTextKeySource() {
  const start = panel.indexOf("function handleTextKey");
  const end = panel.indexOf("function unwind");
  return panel.slice(start, end);
}

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

  test("a bare URL asks linkpreview.ts and renders the same card", () => {
    expect(panel).toContain("function requestPreview(url)");
    expect(panel).toContain("root.previewScript");
    expect(panel).toContain("readonly property var fetched:");
    expect(panel).toContain("modelData.link || linkRow.fetched || ({})");
    // an Apple card still comes from the ssh-fetched attachment, ours from disk
    expect(panel).toContain("String((linkRow.fetched && linkRow.fetched.image)");
  });

  test("an arriving link opens the sheet only on a surface already open", () => {
    expect(widget).toContain("function shareArrivingLink(link)");
    expect(widget).toContain("d.links[d.links.length - 1]");          // newest only, never a queue
    expect(widget).toContain("p.opened === true");                    // panel must already be open
    expect(widget).toContain("root.windowVisible");                   // or the app window
  });

  test("a link you SEND opens the sheet too, and the app button asks the host", () => {
    expect(panel).toContain("var sentUrl = root.firstUrl(completedText)");
    expect(panel).toContain("function openApp()");
    expect(panel).toContain('hostWidget.showApp()');
    // the popout gets out of the way, and closes BEFORE the window is shown
    expect(panel).toContain('hostWidget.close()');
    expect(panel.indexOf("hostWidget.close()")).toBeLessThan(panel.indexOf("hostWidget.showApp()"));
    expect(panel).toContain('tooltipText: "Open the app window (SUPER+M)"');
  });

  test("group rows and tiles show the GROUP's photo, never the last speaker's", () => {
    const bind = 'root.isGroupId(String(modelData.chat || "")) ? String(modelData.chat) : String(modelData.handle || modelData.chat || "")';
    expect(panel.split(bind).length - 1).toBe(2);   // list row + pinned tile
    expect(panel).not.toContain('if (!root.isGroupId(String(modelData.chat || ""))) root.requestAvatar(avatarHandle)');
    expect(panel).not.toContain('if (handle === "" || isGroupId(handle)) return');
  });

  test("share sheet: right-click a link, URL on stdin, never argv", () => {
    expect(panel).toContain("function openShare(u)");
    expect(panel).toContain("qrProc.write(u)");
    expect(panel).toContain("sendShareProc.write(u)");
    expect(panel).toContain('localsend --headless send "$2"');
    expect(panel).toContain('onTapped: root.openShare(String(linkCard.link.url || ""))');
    expect(panel).toContain('if (shareUrl !== "") { closeShare(); return true }');
    expect(widget).toContain('function share(url: string): string { if (!root.automationOn) return root.automationOff;');
    // never the URL as an argv element of qrencode / localsend
    expect(panel).not.toContain('qrencode", ');
    expect(panel).not.toContain("localsend --headless send \"$2\" \"$3\"");
  });

  test("IPC goto only E.164-ifies a full number, never a short code", () => {
    expect(widget).toContain('/^[0-9]{10,}$/.test(want)');
    expect(widget).not.toContain('/^[0-9]+$/.test(want)');
  });

  test("read marks are queued and only applied after a successful load", () => {
    expect(widget).toContain("property var refreshQueue: []");
    expect(widget).not.toContain("property var queued: null");
    const success = panel.indexOf("if (d.ok === true)");
    const mark = panel.indexOf("markThreadRead(root.threadRunningChat,");
    expect(success).toBeGreaterThan(-1);
    expect(mark).toBeGreaterThan(success);
  });

  test("contact management and optional Blip display preferences are separate flows", () => {
    expect(identitySettings).toContain("CHOOSE A CONVERSATION TO REVIEW");
    expect(identitySettings).toContain("WHY THEY ARE HERE");
    expect(identitySettings).toContain("Short codes and service senders can simply be left alone.");
    expect(identitySettings).toContain("Review contact…");
    expect(identitySettings).toContain("Review anyway…");
    expect(identitySettings).toContain("var started = resolver.findCandidates(handle)");
    expect(identitySettings).toContain("directContactPending = directEdit === true && started");
    expect(identitySettings).toContain("Hide short-code senders");
    expect(identitySettings).not.toContain(".slice(0, 12)");
    expect(identitySettings).toContain("phone/email conversations to review");
    expect(identitySettings).toContain("readonly property var auditableConversations: auditableThreads(threads)");
    expect(identitySettings).toContain("resolver.audit.handleCount === auditableConversations.length");
    expect(identitySettings).toContain("Named conversations are included");
    expect(identitySettings).toContain("preferences.hideShortCodeConversations");
    expect(identitySettings).toContain('preferences.setBoolean("hideShortCodeConversations", value)');
    expect(settings).toContain("preferences: root.preferences");
    expect(identitySettings).toContain("What do you want to do? These are separate workflows.");
    expect(identitySettings).toContain("rowSpacing: root.space(12)");
    expect(identitySettings).toContain("columnSpacing: root.space(12)");
    expect(identitySettings).toContain("MANAGE MAC CONTACTS");
    expect(identitySettings).toContain("This never creates a Blip display-name preference.");
    expect(identitySettings).toContain("Skip this when you only want to deduplicate Contacts.");
    // side-by-side workflow cards share the taller card's height, and each
    // card's action pins to the bottom right through a flexible spacer
    expect(identitySettings).toContain("Math.max(manageTask.implicitHeight, namingTask.implicitHeight)");
    expect(identitySettings.split("Item { Layout.fillHeight: true }").length - 1).toBeGreaterThanOrEqual(2);
    expect(identitySettings).toContain("OPTIONAL BLIP DISPLAY NAME");
    expect(identitySettings).toContain("Save Contacts name as display preference");
    expect(identitySettings).toContain("CUSTOM BLIP-ONLY DISPLAY NAME");
    expect(identitySettings).toContain("it is temporary, never saved, and changes nothing in Contacts.");
    expect(identitySettings).toContain("Viewing or opening a card makes no change");
    expect(identitySettings).toContain("CHOOSE A CONVERSATION TO REVIEW");
    expect(identitySettings.indexOf("WHY THEY ARE HERE"))
      .toBeLessThan(identitySettings.indexOf("FIND CONTACT CLEANUP OPPORTUNITIES"));
    expect(identitySettings.indexOf("FIND CONTACT CLEANUP OPPORTUNITIES"))
      .toBeLessThan(identitySettings.indexOf("CHOOSE A CONVERSATION TO REVIEW"));
    expect(identitySettings.indexOf("CHOOSE A CONVERSATION TO REVIEW"))
      .toBeLessThan(identitySettings.indexOf("model: root.unresolved"));
    expect(identitySettings).toContain("Refresh source cards");
    expect(identitySettings).not.toContain("Check Mac Contacts again");
    expect(identitySettings.indexOf("Refresh source cards"))
      .toBeLessThan(identitySettings.indexOf("ContactCardCompare {"));
    expect(identitySettings).toContain("root.resolver.comparison === null");
    expect(identitySettings).toContain("visible: contactWorkspace.editorCard === null && root.resolver");
    expect(identitySettings).toContain("root.resolver.candidates.length === 1");
    expect(identitySettings).not.toContain("root.selectedChoiceIsSaved\n                  && (!root.resolver.comparison");
    expect(identityHelper).not.toContain("requireSavedRepairOwner");
    expect(identityHelper).not.toContain("save the correct Contacts name in Blip before repairing");
    expect(identitySettings).not.toContain("MATCH REMEMBERED BY BLIP");
    expect(identitySettings).not.toContain("Already saved in Blip\"");
    expect(identitySettings).not.toContain('label: "Use"');
    expect(identitySettings).not.toContain("Fix on Mac");
  });

  test("stale unsaved Contacts edits have an explicit two-step recovery", () => {
    expect(identitySettings).toContain("Contacts is holding an unfinished in-memory edit.");
    expect(identitySettings).toContain('? "Discard and close Contacts" : "Resolve pending edit…"');
    expect(identitySettings).toContain("root.resolver.discardUnsavedContacts()");
    expect(identities).toContain('start("discard-unsaved", {})');
  });

  test("contact cleanup scan is read-only triage, never a bulk merge", () => {
    expect(identitySettings).toContain("FIND CONTACT CLEANUP OPPORTUNITIES");
    expect(identitySettings).toContain("Run a read-only Mac Contacts scan");
    // every Contacts mutation announces itself, and a finished scan refreshes
    // quietly without clobbering the mutation's success notice
    expect(identities).toContain("signal contactsMutated()");
    expect(identities.split("contactsMutated()").length - 1).toBeGreaterThanOrEqual(5);
    expect(identities).toContain('if (!quietAudit) notice = result.cached === true');
    // a fingerprint cache hit reports freshness instead of a fake re-scan
    expect(identities).toContain("Contacts hasn't changed since the last scan");
    // the contacts page loads cleanup results on open (cheap when cached)
    expect(identitySettings).toContain("function maybeAutoAudit()");
    expect(identitySettings).toContain("root.resolver.auditContacts(root.reviewHandles(), true)");
    // the scan runs on its OWN process, kicked immediately after a mutation,
    // so it never contends with navigation or edits; the list page shows the
    // in-flight state while previous results stay visible
    expect(identities).toContain("id: auditWorker");
    expect(identities).toContain("property bool auditRunning");
    expect(identities).toContain("function consumeAudit(text)");
    // in-flight scans animate a three-dot indicator (width-stable, monospace)
    expect(identitySettings).toContain('"Scanning" + root.animatedDots');
    // busy notices ("Consolidating the verified source cards…") animate too
    expect(identitySettings).toContain('String(root.resolver.notice).replace(/…$/, "") + root.animatedDots');
    expect(identitySettings).toContain("property int scanDotPhase");
    // stale results gray out while a re-scan is in flight
    expect(identitySettings).toContain("readonly property bool staleWhileScanning");
    // dimming covers the cleanup-opportunities results AND the review list
    expect(identitySettings.split("root.staleWhileScanning ? 0.45 : 1").length - 1).toBeGreaterThanOrEqual(7);
    expect(identitySettings).toContain("likely duplicates");
    expect(identitySettings).toContain("naming conflicts");
    expect(identitySettings).toContain("Review duplicate…");
    expect(identitySettings).toContain("Review conflict…");
    expect(identitySettings).toContain("Focus on ");
    expect(identitySettings).toContain("Every contact change still opens its own preview and confirmation.");
    expect(identitySettings).not.toContain("Merge all");
    expect(identities).toContain("function auditContacts(handles, quiet)");
    expect(identities).toContain('auditWorker.command = ["bun", helperPath, "audit"]');
    expect(identityHelper).toContain('operation === "audit"');
  });

  test("settings navigation keeps contact repair compact and separate from appearance", () => {
    expect(settings).toContain('property string page: "contacts"');
    expect(settings).toContain('visible: root.page === "contacts"');
    expect(settings).toContain('visible: root.page === "appearance"');
    expect(settings).toContain("width: Math.min(parent.width, root.space(1120))");
    expect(identitySettings).toContain('label: "← All conversations"');
    expect(identitySettings).toContain("visible: !root.reviewActive");
    expect(identitySettings).toContain("visible: root.macReviewExpanded");
    expect(identitySettings).toContain("function openContactManagement()");
    expect(identitySettings).toContain("Manage Contacts…");
    expect(identitySettings).toContain("sourceCandidate.cardsExpanded ? sourceCandidate.modelData.cards : []");
    expect(identitySettings).toContain("root.candidateForToken(saved.contactToken)");
    expect(settings).not.toContain("Saved as portable JSON files");
    expect(settings).toContain("Layout.alignment: Qt.AlignTop");
  });

  test("silent settings refreshes preserve stable models and visible state", () => {
    expect(identities).toContain("loading = quiet !== true");
    expect(identities).toContain("if (serialized !== identitiesJson)");
    expect(identities).toContain("pendingReviewHandle = requested");
    expect(identities).toContain('if (!worker.running && root.activeHandle === "") root.load(true)');
    expect(preferences).toContain("if (loaded && serialized === lastSerialized) return true");
  });

  test("Mac contact writes require preview, confirmation, and expose undo", () => {
    expect(identitySettings).toContain('label: "Remove this " + root.handleNoun() + "…"');
    // the undo offer shows only in the workspace of the contact it changed
    expect(identitySettings).toContain("root.handleKey(root.resolver.undoHandle)");
    // the conflict flow speaks in outcomes, not implementation terms: picking
    // a person opens their cards; "session"/identities.json stay out of it
    expect(identitySettings).toContain('"WORKING ON: "');
    expect(identitySettings).toContain("Work on this person");
    expect(identitySettings).toContain("Pick a person below. That only opens their cards for review");
    expect(identitySettings).not.toContain("Select for this session");
    expect(identitySettings).not.toContain("SELECTED FOR THIS SESSION");
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
    expect(identitySettings).toContain("Manage " + '" + sourceCandidate.modelData.recordCount');
    expect(identitySettings).toContain("ContactCardCompare");
    expect(contactCompare).toContain('title: "Compare source cards"');
    expect(contactCompare).toContain('title: "Consolidate into one card"');
    expect(contactCompare).toContain('title: "Or link cards · optional"');
    expect(contactCompare).not.toContain("step: \"");
    expect(contactCompare).toContain("Reload cards from Mac");
    expect(contactCompare).toContain("Back to contact tasks");
    expect(contactCompare).toContain("DIFFERENCES ONLY");
    expect(contactCompare).toContain("sharedRowMap");
    expect(contactCompare).toContain("MERGED PREVIEW");
    expect(contactCompare).toContain("function displayFieldLabel(fieldType, value)");
    expect(contactCompare).toContain('detail.toLowerCase() === fieldType.toLowerCase()');
    expect(contactCompare).toContain("displayFieldLabel(group.name, item.label)");
    expect(contactCompare).toContain('displayFieldLabel("Address", address.label)');
    expect(contactCompare).toContain("Prepare link in Contacts…");
    expect(contactCompare).toContain("CONFIRM AN UPSTREAM CONTACTS CHANGE");
    expect(contactCompare).toContain("Checking makes no changes");
    expect(contactCompare).toContain("Edit in Blip…");
    expect(contactCompare).toContain("cardBox.modelData.sourceName");
    expect(identitySettings).toContain("sourceCard.modelData.sourceName");
    expect(contactCompare).toContain("Text.PlainText");
    expect(contactCompare).not.toContain("Array.isArray(card.phones)");
    expect(identities).toContain("function compareCards(handle, ownerToken, otherOwnerToken)");
    expect(identities).toContain("function prepareLink()");
    expect(identities).toContain("function linkCards()");
    expect(identities).toContain("linkPreview.ready");
    expect(identities).toContain("expectedAction: linkPreview.action");
  });

  test("the contact workspace edits, deletes, and consolidates only after preview", () => {
    expect(contactCompare).toContain("ContactCardEditor");
    expect(contactCompare).toContain("Merge into \" + modelData.sourceName");
    expect(panel).toContain('iconText: "⚙"');
    expect(panel).toContain('tooltipText: "Settings"\n            bordered: false');
    expect(panel).toContain('iconText: "＋"');
    expect(panel).toContain('tooltipText: "New message (n)"\n            bordered: false');
    expect(contactEditor).toContain("Review changes…");
    expect(contactEditor).toContain("Delete this source card…");
    expect(contactEditor).toContain("Review merged contact…");
    expect(contactEditor).toContain("REVIEW CONSOLIDATION");
    expect(contactEditor).toContain("This is a read-only preview. Nothing below has been saved to Contacts.");
    expect(contactEditor).toContain("MERGED CONTACT TO KEEP");
    expect(contactEditor).toContain("DELETE AFTER MERGE");
    expect(contactEditor).toContain("FINAL CONFIRMATION");
    expect(contactEditor).toContain("Back to edit");
    expect(contactEditor).toContain("Save to Mac Contacts");
    expect(contactEditor).toContain("Merge and delete source cards");
    expect(contactEditor).toContain("function cleanLabel(value)");
    expect(contactEditor).toContain("originalLabel: text(item.label)");
    expect(contactEditor).toContain('value === cleanLabel(original) ? original : value');
    expect(contactEditor.indexOf('label: valueList.emptyLabel')).toBeGreaterThan(
      contactEditor.indexOf('model: parent.model'),
    );
    expect(contactEditor.indexOf('label: "Add address"')).toBeGreaterThan(
      contactEditor.indexOf('model: root.previewOpen ? null : addresses'),
    );
    expect(contactEditor).toContain("Text.PlainText");
    expect(identities).toContain("function prepareCardEdit(card, draft)");
    expect(identities).toContain("function prepareCardDelete(card)");
    expect(identities).toContain("function prepareConsolidation(targetCard, draft)");
    expect(identities).toContain("function applyMutation()");
    expect(identities).toContain("mutationPreview.planHash");
  });

  test("app window routes n, slash, digits, and Esc through catch helpers", () => {
    expect(window).toContain("view.catchNavText(");
    expect(window).toContain("view.catchEscape()");
    expect(window).toContain("navCatcher.forceActiveFocus()");
    expect(window).toContain("win.navText(");
    const nav = window.slice(window.indexOf("function navText"), window.indexOf("function saveWinState"));
    expect(nav.indexOf("var typed = event.text")).toBeLessThan(nav.indexOf("Qt.Key_1"));
    expect(nav).toContain("Qt.ShiftModifier");
  });

  test("handleTextKey runs slash, n, and 1-9 before the inThread return", () => {
    const fn = handleTextKeySource();
    expect(fn.indexOf('text === "/"')).toBeLessThan(fn.indexOf("inThread"));
    expect(fn.indexOf('text === "n"')).toBeLessThan(fn.indexOf("inThread"));
    expect(fn.indexOf('text >= "1"')).toBeLessThan(fn.indexOf("inThread"));
    expect(fn).toContain("if (i < 0 || i >= navigationThreads.length) return false");
    expect(fn).toContain("openThread(navigationThreads[i])");
  });

  test("sidebar rows show the 1-9 jump digit", () => {
    expect(panel).toContain("function threadHotkey");
    expect(panel.split("text: root.threadHotkey(modelData)").length - 1).toBe(1);
    const catcher = panel.slice(panel.indexOf("function catchNavText"), panel.indexOf("function catchEscape"));
    expect(catcher).toContain('text >= "1" && text <= "9"');
    expect(catcher).toContain("root.draftPath");
    expect(catcher).toContain("return handleTextKey(text) === true");
    const fn = handleTextKeySource();
    expect(fn).toContain("if (searching || newMode) return false");
  });

  test("conversation search is scheduled from the field text, people first", () => {
    expect(panel).toContain("if (q !== searchQueryRan) searchSeq++");
    expect(panel).toContain("function scheduleSearch");
    expect(panel).toContain("function conversationHits");
    expect(panel).toContain("id: searchWatch");
    expect(panel).toContain("function threadIdentitiesJson");
    expect(panel).toContain("searchProc.write(threadIdentitiesJson())");
    expect(panel).toContain("onAccepted: root.acceptSearchField()");
  });

  test("new-message contact search is scheduled from the field text, not only Enter", () => {
    expect(panel).toContain("function scheduleContactSearch");
    expect(panel).toContain("function newFieldQuery");
    expect(panel).toContain("id: newSearchWatch");
    expect(panel).toContain("running: root.newMode");
    expect(panel).toContain("newSearchTimer.restart()");
    expect(panel).not.toContain("forceLayout");
    expect(panel.indexOf("onAccepted: root.acceptNewField()")).toBeGreaterThan(-1);  });
});
