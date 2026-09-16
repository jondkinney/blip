"""Create a group with its first message using Messages' native compose view.

Only imsg-send --new-group-stdin --yes reaches this path. Message text stays
on stdin; the deep link carries addresses only. No SQL writes or private API.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import selectors
import sqlite3
import subprocess
import time
from urllib.parse import urlencode

MAX_REQUEST = 48 * 1024
MAX_OUTPUT = 48 * 1024
MAX_RECIPIENTS = 31
MAX_TEXT = 4000
CHAT_DB = os.path.expanduser("~/Library/Messages/chat.db")


def request_from_bytes(raw):
    if len(raw) > MAX_REQUEST:
        raise ValueError("Group request is too large")
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError):
        raise ValueError("Invalid group request") from None
    if not isinstance(data, dict) or set(data) != {"recipients", "text"}:
        raise ValueError("Invalid group request")
    people, text = data["recipients"], data["text"]
    if not isinstance(people, list) or not 2 <= len(people) <= MAX_RECIPIENTS:
        raise ValueError("Choose between 2 and 31 recipients")
    handles = []
    for handle in people:
        if not isinstance(handle, str) or len(handle) > 254 or re.search(r"[\x00-\x20\x7f-\x9f\u202a-\u202e\u2066-\u2069]", handle):
            raise ValueError("Invalid recipient")
        if not re.fullmatch(r"\+?[0-9]{3,15}|[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+", handle):
            raise ValueError("Invalid recipient")
        handles.append(handle.lower())
    if len(set(handles)) != len(handles):
        raise ValueError("Duplicate recipient")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT or "\x00" in text:
        raise ValueError("Write a message of at most 4000 characters")
    return {"recipients": handles, "text": text.strip()}


def compose_url(handles):
    return "imessage:open?" + urlencode({"addresses": ",".join(handles)})


def run_script(source, deadline=150):
    """Drain both pipes with independent caps; never expose script errors.

    JXA errors can quote the source, which contains the body. Only structured
    fixed errors and the content-free send-attempt marker leave this module.
    """
    proc = subprocess.Popen(["/usr/bin/osascript", "-l", "JavaScript", "-"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, errors = bytearray(), bytearray()
    end = time.monotonic() + deadline
    try:
        with selectors.DefaultSelector() as streams:
            pending = memoryview(source.encode("utf-8"))
            for pipe, kind in ((proc.stdout, "out"), (proc.stderr, "err"), (proc.stdin, "in")):
                os.set_blocking(pipe.fileno(), False)
                streams.register(pipe, selectors.EVENT_WRITE if kind == "in" else selectors.EVENT_READ, kind)
            while streams.get_map():
                if time.monotonic() >= end:
                    raise TimeoutError("Messages did not respond")
                for key, _ in streams.select(min(0.2, max(0, end - time.monotonic()))):
                    if key.data == "in":
                        try:
                            written = os.write(key.fd, pending[:8192])
                            pending = pending[written:]
                        except BrokenPipeError:
                            pending = memoryview(b"")
                        if not pending:
                            streams.unregister(key.fileobj)
                            key.fileobj.close()
                        continue
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        streams.unregister(key.fileobj)
                        continue
                    buf = output if key.data == "out" else errors
                    if len(buf) + len(chunk) > MAX_OUTPUT:
                        raise ValueError("Messages returned too much data")
                    buf.extend(chunk)
            proc.wait(timeout=max(0.1, end - time.monotonic()))
        data = json.loads(output)
        if proc.returncode != 0 or not isinstance(data, dict):
            raise ValueError("Messages automation failed")
        return data
    except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
        return {"ok": False, "uncertain": b"BLIP_GROUP_SEND_ATTEMPT" in errors,
                "error": "Could not complete Messages automation"}
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        for pipe in (proc.stdin, proc.stdout, proc.stderr):
            if pipe and not pipe.closed:
                pipe.close()


# This script only traverses composer controls. Sidebar and transcript trees
# are excluded: it never inspects message bubbles or contact conversation names.
UI_SCRIPT = r'''
var events = Application("com.apple.systemevents");
var messages = Application("com.apple.MobileSMS");
var process = events.processes.byName("Messages");
var visits = 0;
function attr(node, name) { try { return node.attributes.byName(name).value(); } catch (_) { return null; } }
function find(node, wanted, depth) {
    if (++visits > 180 || depth > 24) throw new Error("controls");
    var id = attr(node, "AXIdentifier");
    if (id === "ConversationList" || id === "CKConversationListCollectionView" || id === "TranscriptCollectionView") return null;
    if (wanted === "body" && id === "messageBodyField") return node;
    if (wanted === "recipients" && id === "MessageEntryView") return null;
    if (wanted === "recipients" && node.role() === "AXTextField" && node.popUpButtons().length) return node;
    var children = node.uiElements();
    if (children.length > 35) return null;
    for (var i = 0; i < children.length; i++) {
        var found = find(children[i], wanted, depth + 1);
        if (found) return found;
    }
    return null;
}
function control(wanted) {
    for (var attempt = 0; attempt < 4; attempt++) {
        visits = 0;
        try { return find(process.windows()[0], wanted, 0); }
        catch (problem) { if (attempt === 3) throw problem; delay(0.2); }
    }
}
function tokenLabels(token) {
    var labels = attr(token, "AXUserInputLabels");
    var description = attr(token, "AXDescription");
    return (Array.isArray(labels) ? labels : []).concat([typeof description === "string" ? description : ""]).join("\n");
}
function matches(labels, handle) {
    if (labels.length > 4096) return false;
    if (handle.indexOf("@") >= 0) {
        var emails = labels.toLowerCase().match(/[^\s,;<>]+@[^\s,;<>]+/g) || [];
        return emails.indexOf(handle.toLowerCase()) >= 0;
    }
    var wanted = handle.replace(/\D/g, "");
    var phones = labels.match(/\+?[0-9][0-9() .-]{1,30}[0-9]/g) || [];
    return phones.some(function(phone) {
        var digits = phone.replace(/\D/g, "");
        return digits === wanted || (wanted.length === 11 && wanted[0] === "1" && digits.length === 10 && wanted.slice(1) === digits);
    });
}
function verifyRecipientsOnce() {
    var field = control("recipients");
    if (!field) throw new Error("recipients");
    var tokens = field.popUpButtons();
    if (tokens.length !== request.recipients.length) throw new Error("recipients");
    var found = {};
    for (var i = 0; i < tokens.length; i++) {
        var labels = tokenLabels(tokens[i]);
        var choices = request.recipients.filter(function(handle) { return matches(labels, handle); });
        if (choices.length !== 1 || found[choices[0]]) throw new Error("recipients");
        found[choices[0]] = true;
    }
}
function verifyRecipients() {
    for (var attempt = 0; attempt < 8; attempt++) {
        try { verifyRecipientsOnce(); return; }
        catch (problem) { if (attempt === 7) throw problem; delay(0.25); }
    }
}
function checkDraft() {
    try {
        if (!messages.running() || !process.windows().length) return {ok:true};
        var field = control("recipients");
        var body = control("body");
        if (field && body && String(body.value() || "").length)
            return {ok:false, error:"Messages has a draft. Clear or send it on the Mac first.", uncertain:false};
        return {ok:true};
    } catch (_) { return {ok:false, error:"Could not inspect the Mac compose window", uncertain:false}; }
}
function main() {
    var attempted = false;
    try {
        messages.activate();
        delay(0.4);
        verifyRecipients();
        var body = control("body");
        if (!body || String(body.value() || "").length) return {ok:false, error:"Messages has a draft. Clear or send it on the Mac first.", uncertain:false};
        if (request.prepareOnly) return {ok:true, prepared:true};
        body.value = request.text;
        body.attributes.byName("AXFocused").value = true;
        verifyRecipients();
        if (!process.frontmost() || attr(body, "AXFocused") !== true || String(body.value()) !== request.text)
            return {ok:false, error:"Messages focus changed. The draft was not sent.", uncertain:false};
        console.log("BLIP_GROUP_SEND_ATTEMPT");
        attempted = true;
        events.keyCode(36);
        return {ok:true, submitted:true};
    } catch (_) {
        return {ok:false, error:"Could not verify the recipients and compose field in Messages.", uncertain:attempted};
    }
}
JSON.stringify(main());
'''


def ui_source(request, prepare_only=False):
    data = dict(request, prepareOnly=prepare_only)
    return "var request = " + json.dumps(data, ensure_ascii=True) + ";\n" + UI_SCRIPT


def last_message_id(con):
    return con.execute("SELECT COALESCE(MAX(ROWID),0) FROM message").fetchone()[0]


def find_created_group(con, baseline, handles, text, decode_body=lambda blob: None):
    """Only new outbound metadata and exact participants can resolve the ID."""
    rows = con.execute("""SELECT c.ROWID, c.guid, c.chat_identifier,
        CASE WHEN length(m.text)<=16000 THEN m.text END,
        CASE WHEN length(m.attributedBody)<=65536 THEN m.attributedBody END, m.error
        FROM chat c JOIN chat_message_join j ON j.chat_id=c.ROWID
        JOIN message m ON m.ROWID=j.message_id
        WHERE m.ROWID>? AND m.is_from_me=1 AND c.style=43 ORDER BY m.ROWID DESC LIMIT 32""", (baseline,)).fetchall()
    wanted = set(handles)
    candidates = {}
    for rowid, guid, chat, plain, blob, error in rows:
        if (plain or decode_body(blob) or "") != text:
            continue
        if not isinstance(guid, str) or not re.fullmatch(r"(?:iMessage|SMS|RCS|any);\+;(?:chat[0-9]{1,40}|[a-fA-F0-9]{32})", guid):
            continue
        people = con.execute("SELECT h.id FROM handle h JOIN chat_handle_join j ON j.handle_id=h.ROWID WHERE j.chat_id=? LIMIT 33", (rowid,)).fetchall()
        if {str(p[0]).lower() for p in people} == wanted and guid.split(";+;", 1)[1] == chat:
            if guid not in candidates:
                candidates[guid] = ({"ok": False, "uncertain": True,
                    "error": "Messages could not send the first message. Check it on the Mac before trying again."}
                    if error else {"ok": True, "guid": guid, "chat": chat})
    return next(iter(candidates.values())) if len(candidates) == 1 else None


def tool_module(name):
    loader = importlib.machinery.SourceFileLoader("blip_" + name.replace("-", "_"), os.path.join(os.path.dirname(__file__), name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def send_group(request, prepare_only=False):
    read = tool_module("imsg-read")
    imsg = tool_module("imsg")
    with read.messages_ui_lock():
        previous = read.frontmost()
        try:
            con = sqlite3.connect("file:" + CHAT_DB + "?mode=ro", uri=True, timeout=5)
            try:
                preflight = run_script(ui_source(request, True).replace("JSON.stringify(main());", "JSON.stringify(checkDraft());"))
                if not preflight.get("ok"):
                    return preflight
                baseline = last_message_id(con)
                opened = subprocess.run(["/usr/bin/open", compose_url(request["recipients"])],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                if opened.returncode:
                    return {"ok": False, "error": "Could not open Messages on the Mac", "uncertain": False}
                time.sleep(2)
                result = run_script(ui_source(request, prepare_only))
                if not result.get("ok") or prepare_only:
                    return result
                for _ in range(40):
                    group = find_created_group(con, baseline, request["recipients"], request["text"], imsg.decode_attributed_body)
                    if group:
                        return group
                    time.sleep(0.25)
                return {"ok": False, "uncertain": True, "error": "Send not confirmed. Check Messages on the Mac before trying again."}
            finally:
                con.close()
        finally:
            read.restore_front(previous)
