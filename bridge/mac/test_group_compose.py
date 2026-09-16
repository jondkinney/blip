"""Synthetic protocol/database/process tests. No Messages or sends."""
import json
import io
import os
import runpy
from contextlib import redirect_stdout, redirect_stderr, nullcontext
from types import SimpleNamespace
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import group_compose as group


class GroupTests(unittest.TestCase):
    request = {"recipients": ["alice@example.com", "bob@example.com"], "text": "Synthetic fixture"}

    def test_request_validation_and_url(self):
        self.assertEqual(group.request_from_bytes(json.dumps(self.request).encode()), self.request)
        for data in [None, [], {}, dict(self.request, text=""), dict(self.request, text="x" * 4001),
                     dict(self.request, recipients=["a@example.com"]),
                     dict(self.request, recipients=["a@example.com", "A@example.com"]),
                     dict(self.request, recipients=["a@example.com\n", "b@example.com"]),
                     dict(self.request, recipients=["a@example.com,b@example.com", "c@example.com"])]:
            with self.assertRaises(ValueError):
                group.request_from_bytes(json.dumps(data).encode())
        with self.assertRaises(ValueError):
            group.request_from_bytes(b" " * (group.MAX_REQUEST + 1))
        self.assertNotIn("body=", group.compose_url(self.request["recipients"]))
        self.assertNotIn(self.request["text"], group.compose_url(self.request["recipients"]))

    def db(self):
        con = sqlite3.connect(":memory:")
        self.addCleanup(con.close)
        con.executescript('''CREATE TABLE chat (guid TEXT, chat_identifier TEXT, style INTEGER);
          CREATE TABLE message (is_from_me INTEGER, text TEXT, attributedBody BLOB, error INTEGER, date INTEGER);
          CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
          CREATE TABLE handle (id TEXT);
          CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);''')
        return con

    def add_chat(self, con, chat, people, text="Synthetic fixture", mine=1):
        c = con.execute("INSERT INTO chat VALUES (?,?,43)", ("iMessage;+;" + chat, chat)).lastrowid
        m = con.execute("INSERT INTO message VALUES (?,?,NULL,0,0)", (mine, text)).lastrowid
        con.execute("UPDATE message SET date=? WHERE ROWID=?", (m, m))
        con.execute("INSERT INTO chat_message_join VALUES (?,?)", (c, m))
        for person in people:
            h = con.execute("INSERT INTO handle VALUES (?)", (person,)).lastrowid
            con.execute("INSERT INTO chat_handle_join VALUES (?,?)", (c, h))
        return c, m

    def test_existing_group_requires_exact_recipients(self):
        con = self.db()
        people = self.request["recipients"]
        self.add_chat(con, "chat1", people[:1])
        self.add_chat(con, "chat2", people + ["other@example.com"])
        self.assertIsNone(group.existing_group(con, people))
        self.add_chat(con, "chat3", list(reversed([p.upper() for p in people])))
        self.assertEqual(group.existing_group(con, people),
                         {"ok": True, "guid": "iMessage;+;chat3", "chat": "chat3"})
        self.add_chat(con, "chat4", people)
        self.assertFalse(group.existing_group(con, people)["ok"])

    def test_existing_group_uses_live_service_row_and_current_participants(self):
        con = self.db()
        people = self.request["recipients"]
        self.add_chat(con, "chat1", people)
        ghost = con.execute("INSERT INTO chat VALUES ('SMS;+;chat1','chat1',43)").lastrowid
        con.execute("INSERT INTO chat_handle_join SELECT ?,handle_id FROM chat_handle_join WHERE chat_id=1", (ghost,))
        self.assertEqual(group.existing_group(con, people)["guid"], "iMessage;+;chat1")
        # An older service row's matching recipients cannot authorize a send
        # when the live conversation has since gained another participant.
        self.add_chat(con, "chat1", people + ["other@example.com"])
        self.assertIsNone(group.existing_group(con, people))

    def test_existing_group_never_enters_the_native_recipient_picker(self):
        for prepare in [True, False]:
            con = self.db()
            self.add_chat(con, "chat1", self.request["recipients"])
            expected = {"ok": True, "guid": "iMessage;+;chat1", "chat": "chat1"}
            read = SimpleNamespace(messages_ui_lock=nullcontext, frontmost=lambda: "", restore_front=lambda previous: None)
            sender = group.tool_module("imsg-send")
            modules = {"imsg-read": read, "imsg": SimpleNamespace(decode_attributed_body=lambda blob: None), "imsg-send": sender}
            with patch.object(group, "tool_module", side_effect=lambda name: modules[name]), \
                 patch.object(group.sqlite3, "connect", return_value=con), \
                 patch.object(group, "run_script", return_value={"ok": True, "submitted": True}) as run, \
                 patch.object(group.subprocess, "run") as open_url, \
                 patch.object(group, "find_created_group", return_value=expected):
                result = group.send_group(self.request, prepare_only=prepare)
                open_url.assert_not_called()
                if prepare:
                    self.assertEqual(result, {"ok": True, "prepared": True, "reused": True})
                    run.assert_not_called()
                else:
                    self.assertEqual(result, expected)
                    run.assert_called_once()
                    self.assertEqual(run.call_args.kwargs, {"language": "AppleScript"})
                    self.assertIn('to chat id "iMessage;+;chat1"', run.call_args.args[0])

    def test_only_new_outbound_exact_body_and_recipients_resolve_a_group(self):
        con = self.db()
        people = self.request["recipients"]
        self.add_chat(con, "chat1", people)
        baseline = group.last_message_id(con)
        self.add_chat(con, "chat2", people, mine=0)
        self.add_chat(con, "chat3", people, text="Different message")
        self.add_chat(con, "chat4", people + ["other@example.com"])
        self.assertIsNone(group.find_created_group(con, baseline, people, self.request["text"]))
        self.add_chat(con, "chat5", people)
        self.assertEqual(group.find_created_group(con, baseline, people, self.request["text"]),
                         {"ok": True, "guid": "iMessage;+;chat5", "chat": "chat5"})
        self.add_chat(con, "chat6", people)
        self.assertIsNone(group.find_created_group(con, baseline, people, self.request["text"]))

    def test_duplicate_rows_in_one_group_and_failed_delivery(self):
        con = self.db()
        people = self.request["recipients"]
        self.add_chat(con, "chat1", people)
        m = con.execute("INSERT INTO message VALUES (1,?,NULL,0,2)", (self.request["text"],)).lastrowid
        con.execute("INSERT INTO chat_message_join VALUES (1,?)", (m,))
        self.assertTrue(group.find_created_group(con, 0, people, self.request["text"])["ok"])
        con.execute("UPDATE message SET error=1 WHERE ROWID=?", (m,))
        self.assertFalse(group.find_created_group(con, 0, people, self.request["text"])["ok"])

    def test_cli_requires_yes_and_treats_post_validation_exceptions_as_uncertain(self):
        script = str(Path(__file__).with_name("imsg-send"))
        for flags in [[], ["--yes"], ["--yes", "--service", "SMS"]]:
            out, err = io.StringIO(), io.StringIO()
            with patch.object(sys, "argv", [script, "--new-group-stdin"] + flags), \
                 patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(json.dumps(self.request).encode()))), \
                 patch.object(group, "send_group", side_effect=ValueError("private fixture source")) as send, \
                 redirect_stdout(out), redirect_stderr(err), self.assertRaises(SystemExit):
                runpy.run_path(script, run_name="__main__")
            if flags == ["--yes"]:
                self.assertTrue(json.loads(out.getvalue())["uncertain"])
                self.assertNotIn("private fixture", out.getvalue() + err.getvalue())
                send.assert_called_once()
            else:
                send.assert_not_called()

    def test_native_script_never_places_a_body_on_argv(self):
        original = subprocess.Popen
        seen = []
        def launch(argv, **kwargs):
            seen.append(argv)
            return original([sys.executable, "-c", "import sys;sys.stdin.buffer.read();print('{\"ok\":true,\"prepared\":true}')"], **kwargs)
        with patch.object(group.subprocess, "Popen", side_effect=launch):
            self.assertEqual(group.run_script(group.ui_source(self.request, True)), {"ok": True, "prepared": True})
            self.assertEqual(group.run_script(group.existing_send_source("iMessage;+;chat1", self.request["text"]), language="AppleScript"), {"ok": True, "prepared": True})
        self.assertEqual(seen, [["/usr/bin/osascript", "-l", "JavaScript", "-"],
                                ["/usr/bin/osascript", "-l", "AppleScript", "-"]])

    def test_oversized_stream_is_killed_without_waiting_for_exit(self):
        original = subprocess.Popen
        def launch(argv, **kwargs):
            return original([sys.executable, "-c", f"import sys,time;sys.stdout.write('x'*{group.MAX_OUTPUT + 1});sys.stdout.flush();time.sleep(30)"], **kwargs)
        started = time.monotonic()
        with patch.object(group.subprocess, "Popen", side_effect=launch):
            result = group.run_script("fixture", deadline=5)
        self.assertFalse(result["ok"])
        self.assertLess(time.monotonic() - started, 2)

    def test_timeout_after_send_attempt_is_uncertain_and_does_not_leak_source(self):
        original = subprocess.Popen
        def launch(argv, **kwargs):
            return original([sys.executable, "-c", "import sys,time;sys.stderr.write('BLIP_GROUP_SEND_ATTEMPT\\nprivate fixture source');sys.stderr.flush();time.sleep(30)"], **kwargs)
        with patch.object(group.subprocess, "Popen", side_effect=launch):
            result = group.run_script("fixture", deadline=0.2)
        self.assertTrue(result["uncertain"])
        self.assertNotIn("private fixture", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
