# Changelog

## Unreleased

- Fix contact deletion and consolidation on macOS. Contacts.app does not expose
  a scriptable delete command; Blip now applies the already previewed, exact-card
  deletion through Apple's current Contacts framework and verifies every removal
  before reporting success. Cross-account merges save the complete surviving card
  first, then delete source cards in account-scoped requests because Contacts can
  reject one save request spanning iCloud and Google backing stores.
- Replace the disabled edit form shown after contact-change preparation with a
  focused read-only review. Consolidation now names the card that will remain,
  the source cards that will be removed, the complete merged contact, and a
  visually separate final destructive confirmation before anything is saved.
- Add a read-only cleanup scan for conversations still shown as phone numbers
  or email addresses. It separates unmatched handles, ordinary one-card
  matches, same-name duplicate-card candidates, and naming conflicts; exposes
  source-account patterns; and can focus the review queue on Contacts matches.
  Duplicate/conflict reviews remain per-person, previewed, and confirmed—there
  is no destructive bulk merge based only on account membership.
- Clarify why unresolved conversations appear in Contacts settings, distinguish
  likely service short codes from people, and hide those short-code rows by
  default behind a portable preference toggle. The review queue now reports
  its full count and scrolls through every matching conversation instead of
  silently stopping after twelve.
- Place repeatable contact-field add actions beneath their current values and
  show Apple’s standard phone labels as Mobile, Home, and Work while preserving
  their original localized tokens when a contact draft is saved.
- Split contact management from optional Blip display-name preferences. Users
  can now compare, edit, delete, consolidate, link, and repair Mac Contacts
  cards without first writing an `identities.json` name rule. Single matches
  are selected for the current session; ambiguous matches require an explicit
  session-only person selection. The UI directs deduplication straight to the
  contact workspace and explains exactly when a portable display rule is useful.
- Show each source card’s macOS Contacts account name (such as iCloud,
  Google, or On My Mac) throughout review, comparison, editing, and destructive
  confirmations. Name-resolution copy now distinguishes a remembered Contacts
  match from a genuinely custom Blip-only display name.
- Add a full in-Blip contact workspace: revision-pinned editing for names,
  work fields, birthday, notes, phones, email addresses, websites, and postal
  addresses; confirmed whole-card deletion; and editable multi-card
  consolidation into a chosen source account. Every apply revalidates its
  preview and saves a private bounded undo receipt first.
- Add explicitly gated Mac Contacts repair from Blip: exact-card preview,
  second confirmation, supported Contacts.app removal, Mac-local undo receipt,
  and post-change revalidation. The restricted SSH key remains unable to turn
  contact writes on by itself.
- Add an in-Blip active-card comparison with bounded contact details, a
  de-duplicated combined view, missing-detail hints, exact-card editing handoff,
  and guarded invocation of Contacts' native link/merge action. Preview and
  execution are separate, the confirmed action is pinned end-to-end, and Blip
  never links during discovery or testing.
- Keep the Settings UI visually stable during five-second configuration checks: silent identity reads no longer toggle visible loading state, and unchanged identity/preference results no longer rebuild QML models or controls.

**Added**
- File-backed appearance preferences with an in-app QML editor: bubble colors,
  app-window opacity, font scale, density, sidebar width, avatar size, and
  corner roundness. `~/.config/blip/preferences.json` is portable, atomically
  written, owner-only, bounded, and reloaded live after an external restore.
- Messages.app pinned conversations, sourced read-only from the Mac's pinning
  plist and rendered in its ordered circular-avatar grid above the regular
  chronological list.
- Explicit contact-name resolution for ambiguous phone/email handles. The QML
  chooser writes a bounded, atomic `~/.config/blip/identities.json` override;
  a source-fix action opens the validated persistent card in Contacts.app on
  the Mac without writing Apple’s private AddressBook database.

**Changed**
- Contact-name repair is now a guided two-stage flow: selecting a candidate is
  harmless, remembering the Contacts match is explicit, and optional Mac repair lists and
  opens every exact source card separately. Generic one-click **Use** and
  **Fix on Mac** controls were removed.
- Settings now separates Contacts from Appearance with tabs. Contact repair is
  a list-to-detail flow with Back/Escape navigation, bounded content width, and
  collapsed Mac/source-card details instead of one enormous settings scroll.

## 2.0.0 — 2026-08-31

The "complete for Fred" release: everything on the roadmap that makes Blip
feel like Messages, plus the hardening a stranger needs.

**Added**
- Contact photos in the sidebar (`imsg avatar` streams the Contacts
  thumbnail; cached 7 days under `~/.cache/blip/avatars`, negative-cached).
- Rich-link cards: URL messages render title / summary / preview image /
  host, click opens the link; a message that is only the URL shows just the card.
- Unread count in the app window title (`Blip (3)`).
- App window: real gutters, no hero chip, looser sidebar (1.9.3, 1.10.1).
- Dedicated ssh key confined on the Mac to the five bridge tools
  (`blip-dispatch`), with its own ControlMaster socket (1.10.0).
- `automation=` switch in `bridge.conf` gating IPC send/read (1.10.0).
- `blip-check` on the Mac + honest failure states in the panel (1.9.0).
- Sent files are kept in `~/.blip/sent` so your own photos stay showable (1.11.0).

**Security / privacy** (Codex audit, `docs/SECURITY.md`)
- Message text never travels in argv on either machine (`--text-stdin`,
  `--text-stdin-bytes`, `osascript` script on stdin) (1.9.4, 1.11.0).
- `bridge.conf` is parsed, never sourced; host validated; `ssh --` (1.9.4).
- Only media/pdf/text attachments reach `xdg-open`; auto-fetch has a hard
  transfer cap; cache refuses symlinks; catch-up fetch bounded (1.9.4).
- Contact names keyed by the last ten digits never pick the wrong person (1.9.4).

**Fixed**
- SUPER+M dying after every plugin update: Omarchy hot-reload leaves the
  old widget answering `qs ipc` (reported upstream, omacom/omarchy#9533);
  the keybind now decides from Hyprland's client list (1.10.1).
- A hidden FloatingWindow is recreated, never re-shown (Quickshell never
  re-maps it) (1.8.3, 1.10.1).
- Four QML-invariant tests had silently failed since 1.8.0 (1.11.0).

## 1.0.0 → 1.8.x — 2026-08-31

Attachments in and out, tapbacks, read receipts, inline replies, edits,
search, new-conversation composer, reply-from-toast, real-time push, the
app window, one-source bridge (`bridge/`, `blip-setup`), failed-delivery
flags, scroll that works. See `git log` — every commit carries the story.
