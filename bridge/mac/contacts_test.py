#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock


SCRIPT = os.path.join(os.path.dirname(__file__), "contacts")
loader = importlib.machinery.SourceFileLoader("blip_contacts", SCRIPT)
spec = importlib.util.spec_from_loader(loader.name, loader)
contacts = importlib.util.module_from_spec(spec)
loader.exec_module(contacts)


class Stdin:
    def __init__(self, value: bytes):
        self.buffer = io.BytesIO(value)


class ContactResolverTests(unittest.TestCase):
    def test_handle_normalization(self):
        self.assertEqual(contacts.normalize_resolve_handle("+1 (555) 010-0001")[1], "5550100001")
        self.assertEqual(contacts.normalize_resolve_handle("Person@Example.COM")[1], "person@example.com")
        with self.assertRaisesRegex(ValueError, "valid phone"):
            contacts.normalize_resolve_handle("--not-a-phone")

    def test_candidates_group_duplicate_cards_by_name(self):
        records = [
            {"name": "Alex Rivera", "uid": "one", "source": "a", "modified": 2, "photo": True},
            {"name": "Alex Rivera", "uid": "two", "source": "b", "modified": 3, "photo": False},
            {"name": "Pat Rivera", "uid": "three", "source": "b", "modified": 1, "photo": False},
        ]
        with mock.patch.object(
            contacts, "matching_records", return_value=("+15550100001", "5550100001", records)
        ), mock.patch.object(
            contacts, "active_record_uids", return_value={record["uid"] for record in records}
        ):
            handle, candidates, by_name = contacts.contact_candidates("ignored")
        self.assertEqual(handle, "+15550100001")
        self.assertEqual([row["name"] for row in candidates], ["Alex Rivera", "Pat Rivera"])
        self.assertEqual(candidates[0]["recordCount"], 2)
        self.assertEqual(candidates[0]["sourceCount"], 2)
        self.assertTrue(candidates[0]["hasPhoto"])
        self.assertEqual(len(candidates[0]["cards"]), 2)
        self.assertEqual(
            [card["accountNumber"] for card in candidates[0]["cards"]], [1, 2]
        )
        self.assertRegex(candidates[0]["cards"][0]["token"], r"^sha256:[0-9a-f]{64}$")
        self.assertNotEqual(candidates[0]["cards"][0]["token"], candidates[0]["token"])
        self.assertEqual(len(by_name["alex rivera"]), 2)
        self.assertRegex(candidates[0]["token"], r"^sha256:[0-9a-f]{64}$")

    def test_candidate_counts_multiple_matching_fields_as_one_card(self):
        records = [{
            "name": "Alex Rivera", "uid": "one", "source": "a", "modified": 2,
            "photo": False, "fields": [
                {"id": "field-1", "value": "+15550100001", "label": "mobile"},
                {"id": "field-2", "value": "5550100001", "label": "home"},
            ],
        }]
        with mock.patch.object(
            contacts, "matching_records", return_value=("+15550100001", "5550100001", records)
        ), mock.patch.object(contacts, "active_record_uids", return_value={"one"}):
            _, candidates, _ = contacts.contact_candidates("ignored")
        self.assertEqual(candidates[0]["recordCount"], 1)
        self.assertEqual(candidates[0]["cards"][0]["matchCount"], 2)

    def test_candidates_exclude_inactive_account_cache_rows(self):
        records = [
            {"name": "Alex Rivera", "uid": "active", "source": "a", "modified": 2,
             "photo": True, "fields": []},
            {"name": "Mom", "uid": "inactive", "source": "b", "modified": 3,
             "photo": True, "fields": []},
        ]
        with mock.patch.object(
            contacts, "matching_records", return_value=("+15550100001", "5550100001", records)
        ), mock.patch.object(contacts, "active_record_uids", return_value={"active"}):
            _, candidates, by_name = contacts.contact_candidates("ignored")
        self.assertEqual([candidate["name"] for candidate in candidates], ["Alex Rivera"])
        self.assertNotIn("mom", by_name)

    def test_active_card_filter_rejects_ids_the_object_layer_did_not_receive(self):
        records = [{"uid": "active"}, {"uid": "inactive"}]
        with mock.patch.object(
            contacts, "run_contact_repair", return_value={"ok": True, "available": ["other"]}
        ):
            with self.assertRaisesRegex(RuntimeError, "active-card id"):
                contacts.active_record_uids(records)

    def test_resolve_input_is_bounded_before_json_parse(self):
        original = sys.stdin
        try:
            sys.stdin = Stdin(b" " * (contacts.MAX_RESOLVE_INPUT_BYTES + 1))
            with self.assertRaisesRegex(ValueError, "too large"):
                contacts.read_resolve_request()
        finally:
            sys.stdin = original

    def test_open_uses_a_validated_addressbook_url_and_fixed_argv(self):
        name = "Alex Rivera"
        key = "5550100001"
        token = contacts.resolve_token(key, name)
        exact_token = contacts.card_token(key, "x", "A/B UUID")
        candidate = {
            "token": token, "name": name, "recordCount": 1,
            "sourceCount": 1, "hasPhoto": True,
            "cards": [{"token": exact_token, "accountNumber": 1, "hasPhoto": True}],
        }
        by_name = {
            name.casefold(): [{
                "name": name, "uid": "A/B UUID", "source": "x", "modified": 3, "photo": True,
            }]
        }
        completed = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(contacts, "read_resolve_request", return_value={
            "operation": "open", "handle": "+15550100001", "token": exact_token,
        }), mock.patch.object(
            contacts, "contact_candidates", return_value=("+15550100001", [candidate], by_name)
        ), mock.patch.object(contacts.subprocess, "run", return_value=completed) as run:
            output = io.StringIO()
            with redirect_stdout(output):
                contacts._cmd_resolve(None)
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], "/usr/bin/open")
        self.assertEqual(argv[1], "addressbook://A%2FB%20UUID")
        result = json.loads(output.getvalue())
        self.assertEqual(result["opened"], True)
        self.assertEqual(result["cardNumber"], 1)
        self.assertEqual(result["cardCount"], 1)
        self.assertEqual(result["accountNumber"], 1)

    def test_open_rejects_an_unknown_card_token_without_launching_contacts(self):
        candidate = {
            "token": contacts.resolve_token("5550100001", "Alex"),
            "name": "Alex", "recordCount": 1, "sourceCount": 1, "hasPhoto": False,
            "cards": [{
                "token": contacts.card_token("5550100001", "x", "uid"),
                "accountNumber": 1, "hasPhoto": False,
            }],
        }
        with mock.patch.object(contacts, "read_resolve_request", return_value={
            "operation": "open", "handle": "+15550100001", "token": "sha256:" + "f" * 64,
        }), mock.patch.object(
            contacts, "contact_candidates", return_value=("+15550100001", [candidate], {
                "alex": [{"name": "Alex", "uid": "uid", "source": "x", "modified": 0, "photo": False}]
            })
        ), mock.patch.object(contacts.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "no longer a candidate"):
                contacts._cmd_resolve(None)
        run.assert_not_called()

    def test_write_gate_requires_an_owner_only_regular_file(self):
        with tempfile.TemporaryDirectory() as root, mock.patch.object(
            contacts, "WRITE_GATE", os.path.join(root, "gate")
        ):
            self.assertFalse(contacts.write_gate_enabled())
            with open(contacts.WRITE_GATE, "wb") as stream:
                stream.write(b"enabled-v1\n")
            os.chmod(contacts.WRITE_GATE, 0o600)
            self.assertTrue(contacts.write_gate_enabled())
            os.chmod(contacts.WRITE_GATE, 0o644)
            self.assertFalse(contacts.write_gate_enabled())
            os.unlink(contacts.WRITE_GATE)
            os.symlink(__file__, contacts.WRITE_GATE)
            self.assertFalse(contacts.write_gate_enabled())

    def test_undo_receipt_is_private_bounded_and_token_pinned(self):
        receipt = {
            "personUid": "person-1", "key": "5550100001", "kind": "phone",
            "fields": [{"id": "field-1", "value": "+15550100001", "label": "mobile"}],
            "name": "Alex Rivera", "handle": "+15550100001", "source": "source-1",
            "cardToken": "sha256:" + "a" * 64,
        }
        with tempfile.TemporaryDirectory() as root, mock.patch.object(
            contacts, "UNDO_DIR", os.path.join(root, "undo")
        ):
            token = contacts.write_undo_receipt(receipt)
            self.assertRegex(token, r"^undo:[0-9a-f]{32}$")
            self.assertEqual(contacts.read_undo_receipt(token)["personUid"], "person-1")
            self.assertEqual(os.stat(contacts.UNDO_DIR).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(os.path.join(contacts.UNDO_DIR, contacts.UNDO_FILE)).st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "no longer available"):
                contacts.read_undo_receipt("undo:" + "f" * 32)
            contacts.clear_undo_receipt(token)
            self.assertFalse(os.path.exists(os.path.join(contacts.UNDO_DIR, contacts.UNDO_FILE)))

    def test_automation_output_cap_kills_a_producer_before_timeout(self):
        started = time.monotonic()
        producer = (
            "import os,time;"
            f"os.write(1,b'x'*{contacts.MAX_REPAIR_PROCESS_BYTES + 1});"
            "time.sleep(10)"
        )
        with self.assertRaisesRegex(RuntimeError, "too much data"):
            contacts.run_bounded_process([sys.executable, "-c", producer], b"{}")
        self.assertLess(time.monotonic() - started, 2)

    def test_comparison_validates_details_and_keeps_raw_ids_private(self):
        key = "5550100001"
        candidate = {
            "token": contacts.resolve_token(key, "Alex Rivera"),
            "name": "Alex Rivera", "recordCount": 2, "sourceCount": 2,
            "hasPhoto": True,
            "cards": [
                {"token": "sha256:" + "b" * 64, "accountNumber": 1, "hasPhoto": True},
                {"token": "sha256:" + "c" * 64, "accountNumber": 2, "hasPhoto": False},
            ],
        }
        records = [
            {"uid": "private-person-one", "source": "source-one", "photo": True},
            {"uid": "private-person-two", "source": "source-two", "photo": False},
        ]
        detail = {
            "displayName": "Alex Rivera", "firstName": "Alex", "middleName": "",
            "lastName": "Rivera", "nickname": "", "organization": "Example",
            "department": "", "jobTitle": "", "birthday": "--09-02", "note": "",
            "phones": [{"label": "mobile", "value": "+1 555 010 0001"}],
            "emails": [], "urls": [], "addresses": [],
        }
        with mock.patch.object(
            contacts, "selected_candidate",
            return_value=("+15550100001", key, candidate, records),
        ), mock.patch.object(
            contacts, "run_contact_repair", return_value={"ok": True, "cards": [detail, detail]},
        ), mock.patch.object(contacts, "write_gate_enabled", return_value=True):
            result = contacts.compare_candidate("+15550100001", candidate["token"])
        self.assertEqual(result["cardCount"], 2)
        self.assertEqual(result["sourceCount"], 2)
        self.assertEqual(result["cards"][0]["accountNumber"], 1)
        self.assertRegex(result["cards"][0]["token"], r"^sha256:[0-9a-f]{64}$")
        self.assertRegex(result["cards"][0]["revision"], r"^sha256:[0-9a-f]{64}$")
        serialized = json.dumps(result)
        self.assertNotIn("private-person-one", serialized)
        self.assertNotIn("private-person-two", serialized)
        self.assertNotIn("source-one", serialized)

        hostile = dict(detail)
        hostile["phones"] = [{"label": "x", "value": "1"}] * 17
        with self.assertRaisesRegex(RuntimeError, "phone list"):
            contacts.validated_card_detail(hostile)

    def test_link_helper_uses_fixed_argv_and_refuses_unsafe_card_ids(self):
        records = [{"uid": "person-1"}, {"uid": "person_2"}]
        completed = (0, b'{"ok":true,"ready":true,"action":"Link Selected Cards"}', b"")
        with mock.patch.object(
            contacts, "run_bounded_process", return_value=completed,
        ) as run:
            result = contacts.run_contact_link("prepare", records)
        argv, payload = run.call_args.args
        self.assertEqual(argv[0], "/usr/bin/osascript")
        self.assertTrue(argv[1].endswith("contact-link.applescript"))
        self.assertEqual(argv[2:], ["prepare", "person-1", "person_2"])
        self.assertEqual(payload, b"")
        self.assertTrue(result["ready"])

        with mock.patch.object(contacts, "run_bounded_process") as run:
            with self.assertRaisesRegex(RuntimeError, "unsafe card identifier"):
                contacts.run_contact_link("prepare", [{"uid": "safe"}, {"uid": "bad/value"}])
        run.assert_not_called()

    def test_link_apply_requires_gate_and_preserves_apple_action(self):
        candidate = {
            "name": "Alex Rivera", "sourceCount": 2,
        }
        selected = (
            "+15550100001", "5550100001", candidate,
            [{"uid": "person-1"}, {"uid": "person-2"}],
        )
        with mock.patch.object(
            contacts, "selected_candidate", return_value=selected,
        ), mock.patch.object(
            contacts, "run_contact_link",
            return_value={"ok": True, "ready": False, "action": "Merge Selected Cards"},
        ), mock.patch.object(contacts, "write_gate_enabled", return_value=True):
            preview = contacts.link_candidate("+15550100001", "sha256:" + "a" * 64, False)
        self.assertFalse(preview["ready"])
        self.assertEqual(preview["action"], "Merge Selected Cards")

        with mock.patch.object(contacts, "require_write_gate", side_effect=PermissionError("disabled")):
            with self.assertRaisesRegex(PermissionError, "disabled"):
                contacts.link_candidate(
                    "+15550100001", "sha256:" + "a" * 64, True,
                    "Merge Selected Cards",
                )

        with mock.patch.object(contacts, "require_write_gate"), mock.patch.object(
            contacts, "selected_candidate", return_value=selected,
        ), mock.patch.object(
            contacts, "run_contact_link",
            return_value={"ok": True, "linked": True, "action": "Link Selected Cards"},
        ):
            with self.assertRaisesRegex(RuntimeError, "action changed"):
                contacts.link_candidate(
                    "+15550100001", "sha256:" + "a" * 64, True,
                    "Merge Selected Cards",
                )

    def test_remove_revalidates_fields_and_saves_undo_before_automation(self):
        preview = {
            "handle": "+15550100001", "name": "Pat Rivera", "kind": "phone",
            "fieldCount": 1, "labels": ["mobile"], "cardNumber": 1,
            "cardCount": 1, "accountNumber": 1, "writeEnabled": True,
        }
        private = {
            "personUid": "person-1", "key": "5550100001", "kind": "phone",
            "fields": [{"id": "field-1", "value": "+15550100001", "label": "mobile"}],
            "name": "Pat Rivera", "handle": "+15550100001", "source": "source-1",
            "cardToken": "sha256:" + "a" * 64,
        }
        events = []
        with mock.patch.object(contacts, "require_write_gate"), mock.patch.object(
            contacts, "inspect_repair", return_value=(preview, private, private["fields"])
        ), mock.patch.object(
            contacts, "write_undo_receipt", side_effect=lambda value: events.append("receipt") or "undo:" + "b" * 32
        ), mock.patch.object(
            contacts, "run_contact_repair",
            side_effect=lambda value: events.append("automation") or {"ok": True, "removed": True, "fieldCount": 1},
        ):
            result = contacts.remove_from_contact(
                "+15550100001", private["cardToken"], "sha256:" + "c" * 64
            )
        self.assertEqual(events, ["receipt", "automation"])
        self.assertTrue(result["removed"])
        self.assertRegex(result["undoToken"], r"^undo:")

    def test_inspect_refuses_the_saved_correct_contact(self):
        key = "5550100001"
        correct = {
            "token": contacts.resolve_token(key, "Alex Rivera"),
            "name": "Alex Rivera", "recordCount": 1, "sourceCount": 1,
            "hasPhoto": False, "cards": [],
        }
        wrong = {
            "token": contacts.resolve_token(key, "Pat Rivera"),
            "name": "Pat Rivera", "recordCount": 1, "sourceCount": 1,
            "hasPhoto": False, "cards": [],
        }
        record = {
            "name": "Alex Rivera", "uid": "person-1", "source": "source-1",
            "kind": "phone", "modified": 0, "photo": False,
        }
        with mock.patch.object(
            contacts, "selected_card",
            return_value=("+15550100001", key, correct, record, 1, 1),
        ), mock.patch.object(
            contacts, "contact_candidates",
            return_value=("+15550100001", [correct, wrong], {}),
        ), mock.patch.object(contacts, "run_contact_repair") as repair:
            with self.assertRaisesRegex(ValueError, "saved correct contact"):
                contacts.inspect_repair(
                    "+15550100001", "sha256:" + "a" * 64, correct["token"]
                )
        repair.assert_not_called()

    def test_card_edit_requires_revision_preview_and_writes_receipt_before_apply(self):
        detail = {
            "displayName": "Alex Rivera", "firstName": "Alex", "middleName": "",
            "lastName": "Rivera", "nickname": "", "organization": "",
            "department": "", "jobTitle": "", "birthday": "", "note": "",
            "phones": [{"label": "mobile", "value": "+15550100001"}],
            "emails": [], "urls": [], "addresses": [],
        }
        draft = contacts.card_draft({**detail, "nickname": "Lex"})
        token = "sha256:" + "b" * 64
        owner = "sha256:" + "a" * 64
        candidate = {
            "name": "Alex Rivera", "recordCount": 1, "sourceCount": 1,
            "cards": [{"accountNumber": 1}],
        }
        selected = (
            "+15550100001", "5550100001", candidate,
            [{"uid": "person-1", "source": "source-1"}],
            {"uid": "person-1", "source": "source-1"}, 1, 1,
        )
        events = []
        edited = {**detail, "nickname": "Lex"}
        with mock.patch.object(contacts, "owned_card", return_value=selected), mock.patch.object(
            contacts, "describe_records", return_value=[detail]
        ), mock.patch.object(contacts, "write_gate_enabled", return_value=True):
            preview, _ = contacts.prepare_card_edit(
                "+15550100001", owner, token, contacts.card_revision(detail), draft
            )
        self.assertEqual(preview["changedFields"], ["nickname"])
        self.assertRegex(preview["planHash"], r"^sha256:[0-9a-f]{64}$")

        with mock.patch.object(contacts, "require_write_gate"), mock.patch.object(
            contacts, "prepare_card_edit", return_value=(preview, {
                "personUid": "person-1", "before": detail, "after": draft,
                "handle": "+15550100001", "name": "Alex Rivera", "cardToken": token,
                "planHash": preview["planHash"],
            })
        ), mock.patch.object(
            contacts, "write_undo_receipt",
            side_effect=lambda value: events.append("receipt") or "undo:" + "c" * 32,
        ), mock.patch.object(
            contacts, "run_contact_repair",
            side_effect=lambda value: events.append("automation") or {
                "ok": True, "edited": True, "card": edited,
            },
        ):
            result = contacts.apply_card_edit(
                "+15550100001", owner, token, contacts.card_revision(detail), draft,
                preview["planHash"],
            )
        self.assertEqual(events, ["receipt", "automation"])
        self.assertTrue(result["applied"])

    def test_consolidation_plan_pins_every_card_and_keeps_raw_ids_private(self):
        base = {
            "displayName": "Alex Rivera", "firstName": "Alex", "middleName": "",
            "lastName": "Rivera", "nickname": "", "organization": "",
            "department": "", "jobTitle": "", "birthday": "", "note": "",
            "phones": [], "emails": [], "urls": [], "addresses": [],
        }
        other = {**base, "emails": [{"label": "home", "value": "alex@example.com"}]}
        key = "5550100001"
        records = [
            {"uid": "private-1", "source": "source-1"},
            {"uid": "private-2", "source": "source-2"},
        ]
        tokens = [contacts.card_token(key, record["source"], record["uid"]) for record in records]
        candidate = {
            "name": "Alex Rivera", "recordCount": 2, "sourceCount": 2,
            "cards": [{"accountNumber": 1}, {"accountNumber": 2}],
        }
        revisions = [
            {"token": tokens[0], "revision": contacts.card_revision(base)},
            {"token": tokens[1], "revision": contacts.card_revision(other)},
        ]
        with mock.patch.object(
            contacts, "selected_candidate",
            return_value=("+15550100001", key, candidate, records),
        ), mock.patch.object(
            contacts, "describe_records", return_value=[base, other],
        ), mock.patch.object(contacts, "write_gate_enabled", return_value=True):
            preview, private = contacts.prepare_consolidation(
                "+15550100001", "sha256:" + "a" * 64, tokens[0], revisions,
                contacts.card_draft(other),
            )
        self.assertEqual(preview["action"], "consolidate")
        self.assertEqual(preview["sourceCardCount"], 1)
        self.assertNotIn("private-1", json.dumps(preview))
        self.assertEqual(private["targetUid"], "private-1")

        changed = [dict(item) for item in revisions]
        changed[1]["revision"] = "sha256:" + "f" * 64
        with mock.patch.object(
            contacts, "selected_candidate",
            return_value=("+15550100001", key, candidate, records),
        ), mock.patch.object(contacts, "describe_records", return_value=[base, other]):
            with self.assertRaisesRegex(ValueError, "source card changed"):
                contacts.prepare_consolidation(
                    "+15550100001", "sha256:" + "a" * 64, tokens[0], changed,
                    contacts.card_draft(other),
                )


if __name__ == "__main__":
    unittest.main()
