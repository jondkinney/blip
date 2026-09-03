#!/usr/bin/env python3
"""Boundary and mapping tests for Messages pinned conversations."""

import importlib.machinery
import importlib.util
import contextlib
import io
import json
import os
import plistlib
import sqlite3
import tempfile
import unittest
from types import SimpleNamespace


def load_imsg():
    path = os.path.join(os.path.dirname(__file__), "imsg")
    loader = importlib.machinery.SourceFileLoader("blip_imsg", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


imsg = load_imsg()


class PinningPlistTests(unittest.TestCase):
    def test_reads_ordered_unique_bounded_tokens(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "pins.plist")
            with open(path, "wb") as handle:
                plistlib.dump({"pD": {"pP": ["one", "two", "one", "bad\nvalue", 4]}}, handle)
            self.assertEqual(imsg._read_pinned_tokens(path), ["one", "two"])

    def test_wrong_shape_symlink_and_oversize_fail_closed(self):
        with tempfile.TemporaryDirectory() as root:
            target = os.path.join(root, "target.plist")
            link = os.path.join(root, "link.plist")
            with open(target, "wb") as handle:
                plistlib.dump({"other": []}, handle)
            self.assertEqual(imsg._read_pinned_tokens(target), [])
            os.symlink(target, link)
            self.assertEqual(imsg._read_pinned_tokens(link), [])
            with open(target, "wb") as handle:
                handle.write(b"x" * (imsg.MAX_PINNING_BYTES + 1))
            self.assertEqual(imsg._read_pinned_tokens(target), [])


class PinMappingTests(unittest.TestCase):
    def test_maps_dm_group_and_original_group_tokens_in_order(self):
        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.executescript("""
            CREATE TABLE chat (
              ROWID INTEGER PRIMARY KEY,
              chat_identifier TEXT,
              group_id TEXT,
              original_group_id TEXT
            );
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            INSERT INTO chat VALUES (1, '+15551234567', NULL, NULL);
            INSERT INTO chat VALUES (2, '+15551234567', NULL, NULL);
            INSERT INTO chat VALUES (3, 'chat999', 'group-token', 'old-token');
            INSERT INTO message VALUES (10, 100);
            INSERT INTO message VALUES (11, 200);
            INSERT INTO message VALUES (12, 150);
            INSERT INTO chat_message_join VALUES (1, 10);
            INSERT INTO chat_message_join VALUES (2, 11);
            INSERT INTO chat_message_join VALUES (3, 12);
        """)
        self.assertEqual(
            imsg.pinned_chat_ids(
                con,
                ["+15551234567", "group-token", "old-token", "missing", "group-token"],
            ),
            ["+15551234567", "chat999"],
        )

    def test_chat_json_deduplicates_parallel_service_rows(self):
        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.executescript("""
            CREATE TABLE chat (
              ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
              room_name TEXT, service_name TEXT, group_id TEXT, original_group_id TEXT,
              style INTEGER
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (
              ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT,
              attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (
              ROWID INTEGER PRIMARY KEY, transfer_name TEXT, mime_type TEXT
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            CREATE TABLE chat_recoverable_message_join (message_id INTEGER);
            INSERT INTO chat VALUES (1, '+15551234567', NULL, NULL, 'SMS', NULL, NULL, 45);
            INSERT INTO chat VALUES (2, '+15551234567', NULL, NULL, 'iMessage', NULL, NULL, 45);
            INSERT INTO handle VALUES (1, '+15551234567');
            INSERT INTO message VALUES (10, 100, 'old', NULL, 0, 1);
            INSERT INTO message VALUES (11, 200, 'new', NULL, 0, 1);
            INSERT INTO chat_message_join VALUES (1, 10);
            INSERT INTO chat_message_join VALUES (2, 11);
        """)
        original = imsg.pinned_chat_ids
        imsg.pinned_chat_ids = lambda _con: ["+15551234567"]
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                imsg.cmd_chats(con, SimpleNamespace(n=300, json=True, no_names=True))
            rows = json.loads(output.getvalue())
        finally:
            imsg.pinned_chat_ids = original
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["last_text"], "new")
        self.assertEqual(rows[0]["pinned_order"], 0)

    def test_chat_json_labels_an_attachment_without_leaking_placeholder_text(self):
        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.executescript("""
            CREATE TABLE chat (
              ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
              room_name TEXT, service_name TEXT, group_id TEXT, original_group_id TEXT,
              style INTEGER
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (
              ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT,
              attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (
              ROWID INTEGER PRIMARY KEY, transfer_name TEXT, mime_type TEXT
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            CREATE TABLE chat_recoverable_message_join (message_id INTEGER);
            INSERT INTO chat VALUES (1, 'chat999', NULL, 'chat999', 'iMessage', NULL, NULL, 43);
            INSERT INTO handle VALUES (1, '+15551234567');
            INSERT INTO message VALUES (10, 100, '￼', NULL, 0, 1);
            INSERT INTO chat_message_join VALUES (1, 10);
            INSERT INTO attachment VALUES (20, 'photo.HEIC', 'image/heic');
            INSERT INTO message_attachment_join VALUES (10, 20);
        """)
        original_pins = imsg.pinned_chat_ids
        original_names = imsg.unified_names
        imsg.pinned_chat_ids = lambda _con: []
        imsg.unified_names = lambda _handles: {}
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                imsg.cmd_chats(con, SimpleNamespace(n=300, json=True, no_names=True))
            rows = json.loads(output.getvalue())
        finally:
            imsg.pinned_chat_ids = original_pins
            imsg.unified_names = original_names
        self.assertIsNone(rows[0]["name"])
        self.assertEqual(rows[0]["last_attachment"]["mime"], "image/heic")

    def test_named_group_migrations_coalesce_only_with_the_same_participants(self):
        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.executescript("""
            CREATE TABLE chat (
              ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
              room_name TEXT, service_name TEXT, group_id TEXT, original_group_id TEXT,
              style INTEGER
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (
              ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT,
              attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (
              ROWID INTEGER PRIMARY KEY, transfer_name TEXT, mime_type TEXT
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            CREATE TABLE chat_recoverable_message_join (message_id INTEGER);
            INSERT INTO chat VALUES (1, 'old-group', 'Partners', NULL, 'iMessage', 'old', NULL, 43);
            INSERT INTO chat VALUES (2, 'new-group', 'Partners', NULL, 'iMessage', 'new', 'old', 43);
            INSERT INTO chat VALUES (3, 'other-group', 'Partners', NULL, 'iMessage', 'other', NULL, 43);
            INSERT INTO handle VALUES (1, '+15550000001');
            INSERT INTO handle VALUES (2, '+15550000002');
            INSERT INTO handle VALUES (3, '+15550000003');
            INSERT INTO message VALUES (10, 100, 'old', NULL, 0, 1);
            INSERT INTO message VALUES (11, 200, 'new', NULL, 0, 1);
            INSERT INTO message VALUES (12, 150, 'different people', NULL, 0, 3);
            INSERT INTO chat_message_join VALUES (1, 10);
            INSERT INTO chat_message_join VALUES (2, 11);
            INSERT INTO chat_message_join VALUES (3, 12);
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO chat_handle_join VALUES (1, 2);
            INSERT INTO chat_handle_join VALUES (2, 1);
            INSERT INTO chat_handle_join VALUES (2, 2);
            INSERT INTO chat_handle_join VALUES (3, 1);
            INSERT INTO chat_handle_join VALUES (3, 3);
        """)
        original_pins = imsg.pinned_chat_ids
        original_names = imsg.unified_names
        imsg.pinned_chat_ids = lambda _con: ["old-group"]
        imsg.unified_names = lambda _handles: {}
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                imsg.cmd_chats(con, SimpleNamespace(n=300, json=True, no_names=True))
            rows = json.loads(output.getvalue())
        finally:
            imsg.pinned_chat_ids = original_pins
            imsg.unified_names = original_names
        self.assertEqual(len(rows), 2)
        merged = next(row for row in rows if row["id"] == "new-group")
        self.assertEqual(merged["aliases"], ["new-group", "old-group"])
        self.assertEqual(merged["messages"], 2)
        self.assertEqual(merged["pinned_order"], 0)
        self.assertIn("other-group", [row["id"] for row in rows])


if __name__ == "__main__":
    unittest.main()
