# Changelog

## Unreleased

- Recover consolidations through Contacts.app when CNContactStore faults:
  some real synced cards hold a damaged stored row that fails EVERY native
  write or deletion with Cocoa 134092 while Contacts.app's own path still
  works. Native failures now report their stage machine-readably, and the
  pipeline finishes the exact reviewed plan through the app: setCard for the
  survivor, a guarded delete-fallback for already-confirmed source cards.
  Along the way two Contacts scripting regressions on current macOS were
  fixed: adding entries via the add-to-person Apple event errors with "No
  error. (0)" (entries now push onto the person's collection specifiers,
  which also un-breaks undo/restore), and add-only collection edits no
  longer remove-and-recreate every entry — existing fields keep their stable
  ids and damaged rows stay untouched.
- Fix the persistent consolidation failure (Cocoa 134092 at "update
  survivor"): rebuilding a card's phone/email collections forces contactsd to
  fault out and delete every existing value row, and one damaged stored row
  fails the whole save — every time, not transiently. The native writer now
  REUSES the card's own labeled values when label+value are unchanged and
  leaves an equal birthday untouched (a synced birthday carries
  calendar/timezone the draft's bare components lack). Compounding it,
  Contacts.app's scripting layer reports unlabeled values under default kind
  names ("Email", "Phone"), so drafts could never match — and silently
  gained literal custom labels; those names now normalize back to unlabeled.
  Verified live: an update sending a card's exact current values failed on
  every attempt before, succeeds after.
- Fix contact consolidation failing with "Contacts could not save this card
  in its source account" and "Contacts changed the merged card while saving
  it". Two real defects, both verified live against synthetic replica cards:
  saves can throw a transient Cocoa 134092 while contactsd refreshes CardDAV
  accounts (Blip's own preflight launches Contacts.app, which triggers those
  refreshes), so every mutating stage in contact-delete.swift now retries on
  a fresh store session; and the post-save verification read Contacts.app's
  stale view immediately after a CNContactStore commit, so it now settle-polls
  before comparing. Residual failures name their stage and error code.
- Bubble right-clicks now offer only Copy message; Copy vCard and Edit
  contact live where the click names a person — the pinned tiles and the
  conversation rows in the sidebar.
- Fix contact editors opening with empty phone/email/address lists right
  after a merge: Contacts.app's long-lived process serves STALE person
  objects after external store changes (collections vanish while scalars
  still read), and a draft seeded from that view would propose deleting the
  fields. Every describe is now cross-checked against fresh CNContactStore
  collection counts (new native "counts" op) and retried until the app's
  view settles, failing honestly if it never does.
- Animate the busy notices too: any in-flight operation's footer message
  ("Consolidating the verified source cards…", "Saving…", "Verifying…")
  cycles its ellipsis as the same three-dot indicator, and the graying now
  also covers the Find-contact-cleanup-opportunities results (summary
  counts, duplicate/conflict rows, footnotes), not just the review list.
- Gray out the stale cleanup results (review rows and the summary line) at
  45% opacity while a re-scan is in flight, fading back when the fresh
  results land; a first scan with nothing stale dims nothing.
- Animate a three-dot progress indicator on the Scan button while a cleanup
  scan is in flight (width-stable in the monospace face, so the button never
  jitters).
- Fix "Contacts could not update email addresses: Message not understood"
  during merge recovery: the third broken Contacts scripting event on
  current macOS — remove-entry-from-person — surfaced whenever the
  Contacts.app fallback had to REPLACE a collection (e.g. a survivor whose
  email carried a different label than the merged draft). Field removal now
  deletes the entry specifier, which works; this also repairs the
  "Remove this number/email" flow, which used the same broken event.
- Skip the full cleanup scan when nothing changed: the Mac now answers a
  cheap store fingerprint (per-account row count + newest modification
  stamp), every scan result is cached with the fingerprint it was taken
  under (~/.local/state/blip/audit-cache.json, bounded and owner-only), and
  a scan request whose conversation set matches first pays one fast
  round-trip — unchanged store means the cached cleanup opportunities load
  instantly, including across shell restarts. The contacts page now loads
  results automatically on open, and a cache hit says "Cleanup results are
  current" instead of pretending to re-scan.
- Run the cleanup re-scan on its own dedicated process, kicked off the
  moment a merge/edit/delete lands instead of waiting for the review to
  close. Scans no longer contend with navigation or further edits, the Scan
  button shows "Scanning…" while a query is in flight, and the previous
  results stay visible until the fresh ones land (they used to vanish during
  every scan).
- Order the cross-name merge union by the same largest-account-first rule as
  every other view; it was concatenating the selected person's cards first.
- Fix the cross-name merge silently opening a one-card comparison instead:
  identities.ts (the Linux broker that bounds every Mac request) did not
  know the otherOwnerToken field and dropped it; it now validates and
  forwards it for compare, merge-prepare, and merge, rejecting a duplicate
  token.
- Add cross-name merging for conflicting cards: when two differently-named
  people share a number or email (a married-name change, say), the other
  person's row now offers "Merge with <selected person>…". It opens the
  standard compare/merge workspace spanning BOTH people's cards — pick the
  survivor and adjust the name in the review. The scope requires both owner
  tokens explicitly, is merge-only (per-card edit/delete and linking keep
  single-person authority), renumbers accounts over the union, and reuses
  the same revisions, plan hash, and undo receipt as same-name merges.
- Say "number"/"email" instead of "handle" in the conflict flow: the removal
  button reads "Remove this number…"/"Remove this email…", and the picker,
  row kickers, and explainers follow suit.
- Fix compare-view account labels de-aligning from the card list: the
  account-ordering change re-sorted one of two positionally-linked lists.
- Stop the consolidate section from dead-ending on single-card people: with
  one source card the section (header, merged preview) is hidden, and when a
  DIFFERENT name shares the handle it is replaced by "Same person under
  another name?" guidance naming the other candidate and the exact
  rename-then-merge steps.
- Fix "← All conversations" doing nothing right after a completed merge:
  the automatic cleanup re-scan started immediately and occupied the single
  bridge worker, and review dismissal silently refuses while the worker runs.
  The re-scan now waits until the review is closed (the only place its
  results are visible), and a running scan no longer blocks dismissal.
- Order source accounts by size everywhere cards are numbered and compared:
  the account with the most contacts is always card 1 (leftmost), instead of
  whichever store's folder name happened to sort first — so iCloud vs Gmail
  no longer swap sides between contacts.
- Stop reporting "Contacts changed the merged card while saving it" for
  merges that applied perfectly: the post-save verification demanded the
  read-back match the reviewed draft byte-for-byte, but the writer reuses a
  card's existing rows and appends additions, so collections can read back
  in a different order. Verification now compares content order-insensitively
  and waits out busy-sync windows longer (6s instead of 3.2s).
- Reword the conflicting-names flow in outcome language: the picker now says
  Contacts has different people named for this handle and that picking one
  only opens their cards for review (temporary, never saved, changes
  nothing), the button reads "Work on this person…" instead of "Select for
  this session", the selected banner reads "Working on", and the explainers
  name the follow-up actions — edit cards, merge duplicates, or remove the
  handle from the wrong card. identities.json no longer appears in this flow.
- Scope the post-change undo offer to the contact it changed: one person's
  merge receipt no longer follows the user into another person's workspace.
  The receipt itself is unchanged — returning to that contact in the same
  session still offers the undo.
- Refresh the contact cleanup scan automatically after any Mac Contacts
  change (merge, edit, delete, link, field removal, undo): a finished scan
  re-runs quietly with the same conversation set, without clobbering the
  mutation's success notice. The section heading is now singular ("Find
  contact cleanup opportunities").
- Equalize the two contact workflow cards ("Manage Mac Contacts" and the
  optional display preference): shown side by side they now share the taller
  card's height instead of ending at different edges, and each card's action
  button pins to the bottom-right corner instead of floating mid-card.
- Fix group right-clicks always reporting "No contact person is available":
  the participants list crosses a QML property boundary as a QVariantList,
  for which Array.isArray() is false, so the per-person menu never saw it.
  Participant iteration now indexes by length instead of gating on isArray.
- The appearance page now uses the full window: the live preview fills the
  available space (fit by both width and height, centered) and the controls
  pin to the right edge at a fixed measure. The preview now depicts the app
  window's default 1040×720 geometry instead of the live window — mirroring
  the live window made 100% structurally impossible — and reaches a
  pixel-true 100% (never upscaling past it) whenever the workspace has room.
- A previewable pasted or dropped attachment (png/jpg/gif/webp/bmp/svg) shows
  the image itself in the compose chip; non-previewable files like a vCard
  keep the filename pill, which also remains the fallback while a preview
  decodes or if it fails.
- Open settings on the Appearance tab, now listed first; editing a contact
  still jumps straight to Contacts. The live app preview is now a true
  miniature: the whole mock window is laid out at real app dimensions (raw-px
  sidebar, spaceReal avatars, the window's own gutters) and shrunk by one
  uniform scale transform, replacing the old per-part approximations.
- Center the avatar and name inside pinned-conversation tiles: the tile now
  sizes itself to its content with even padding instead of a fixed tail that
  left extra space under the label.
- Make chronological sidebar rows contiguous: each row absorbs half the old
  inter-row gap, so the hover highlight fills the whole area up to the
  hairline separator instead of stopping short of it. Separators touching a
  hovered or selected row hide so the highlight reads as one clean block.
- Keep the settings page still while dragging appearance sliders: the page's
  own chrome uses scale values frozen at open, and only the live preview
  (plus the app behind it) tracks the moving density/font/corner values.
- Stop the contacts tab hint from stretching settings past the narrow popout
  width — it now elides instead of forcing an unbounded implicit width.
- Move the popout's new-message and open-app-window buttons into the header,
  upper right beside the gear, ordered by function: start a conversation,
  promote to the app window, then settings.
- Double the popout's width (and give it a little extra height) while the
  appearance settings page is showing, so the live preview sits beside the
  controls instead of stacking above them. New `panelsettings <page>` IPC
  opens the settings pages inside the popout the way `settings`/`appearance`
  do for the window. The wide panel now covers the contacts pages too — the
  review/compare workflows need the room, and one width means no resize jump
  when switching tabs. The two-column threshold dropped to space(700) with
  smaller column minimums: the old 940 threshold sat too close to the wide
  popout width (both shrink with density while the panel padding does not,
  so low density flipped it back to stacked) and above what a narrow app
  window can offer.
- Preserve the natural aspect ratio of tall link-preview artwork, allow cards
  to grow beyond the old shallow banner cap, and render tapback reactions on
  unfurled cards. Conversation headers now use Messages' pinned group title,
  short emoji-only messages use the large bubble-free Messages treatment, and
  incoming group-message runs show the sender's avatar beside their last item.
- Keep the Wayland clipboard owner alive after exporting a contact, so Copy
  vCard reliably pastes a real `.vcf` file instead of leaving an empty clipboard.
- Add conversation/message context menus for contact work. Direct chats offer
  Copy vCard and Edit contact; groups expand those actions into named
  participant submenus. vCards are exported by macOS Contacts as real `.vcf`
  clipboard files, while editing jumps into the exact Blip contact workspace.
- Add subtle post-avatar separators between chronological sidebar discussions,
  matching the visual grouping used by Messages on macOS.
- Balance the vertical space above and below sidebar search before the pinned
  grid, and carry Mac-resolved participant names into group contact menus.
- Enlarge tapback reactions, add Messages-like background padding and two-dot
  tails, raise them away from message text, and render their fill fully opaque
  without the badge-style outline.
- Tailor contact context menus to direct chats, groups, and message-only rows,
  eliminating hidden blank entries and irrelevant disabled flyouts.
- Fix Mac contact edits that failed with “Message not understood”: unchanged
  phone/email/address collections now retain their source fields, while an
  actual replacement removes the concrete Contacts field specifiers.
- Offer an explicit two-step recovery when Contacts is holding an unsaved edit
  left by a failed automation attempt; it closes Contacts without saving only
  after the user confirms that any pending Mac-side edit may be discarded.
- Make cross-account consolidation commit and verify the chosen surviving
  card before any source deletion. Source cards are then deleted independently,
  so a rejected iCloud update can never remove the corresponding Gmail card.
- Match the Appearance preview bubbles to the live sender-corner treatment,
  and add a portable 12/24-hour conversation-list time preference (AM/PM by
  default).
- Coalesce migrated named group-chat records when their title and exact
  participant set agree. Pin state follows the one logical conversation, the
  newest source remains the send target, and history/unread state spans every
  retained source identifier.

- Remove the sidebar's duplicate left inset in the app window so search,
  pinned conversations, and the message list sit closer to the window edge
  while retaining breathing room beside the conversation divider.
- Match Messages' compact sidebar hierarchy by moving Settings into the Blip
  header and removing redundant Messages/Pinned labels. Pinned direct and
  group conversations now use short names from Contacts' unified-card view.
- Replace Messages' raw attachment placeholder glyph in conversation previews
  with Photo, Video, Audio message, Contact card, or Attachment.
- Suppress a message body when it contains only the URL already represented by
  an unfurled link card, including when its preview metadata canonicalizes away
  tracking parameters. Captions and other accompanying text remain visible.
- Make message links inherit the bubble's readable text color, render grouped
  bubble corners as one translucent shape without a darker overlap, and cap
  inline media in logical UI units on wide windows. Retina PNG density is now
  honored so 144-DPI screenshots render at their intended 2× logical scale.
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
- **Reads now reach the Mac, and your phone.** Blip's "mark all read" cleared
  the badge on Linux and nothing else; the iPhone kept its red dots. The old
  note called this impossible because `open imessage://<handle>` does not flip
  `is_read` — true, but Messages has a **Conversation ▸ Mark All as Read** menu
  item, and menu items are scriptable. `imsg-read` on the Mac clicks it, and
  the collector calls that after the local marks are committed. Verified by
  round trip on a real Mac: unread → Blip's mark-all-read → read, on both
  machines. Because it goes through Messages rather than writing `chat.db`, the
  change syncs to every device the way any read does.
  - Needs **Accessibility** for `/usr/libexec/sshd-keygen-wrapper` alongside the
    Full Disk Access it already had. `blip-check` reports it; without it
    everything else still works.
  - `push_read=` in `bridge.conf`: `all` (default — only the explicit
    mark-all-read gesture), `thread` (also every conversation you open), `off`.
    The default is `all` because `--all` provably does not disturb the Mac,
    while pushing one conversation has to open it, which pulls Messages to the
    front of whatever the Mac is doing.
  - **If you have read receipts turned on, senders will now see them.** That is
    what marking a message read means; it was previously impossible for Blip to
    do, and now it is not.

- **A re-keyed group is one conversation again.** Messages re-keys a group
  (a re-invite, an iCloud re-sync, a service move) by writing a NEW chat row
  with the same name and the same members — Messages.app shows one thread,
  Blip listed one per row ("2x Sportsball!", twice again as a pinned tile).
  The bridge now clusters group rows by (name, members), lists the row
  Messages is writing to now, sums the message count, names the older rows as
  `aliases`, and `thread --chat` loads every row so the history is whole. The
  collector folds threads, unread counts and oldest-unread stamps onto the
  live id, and caches the map in `state.json` so a shallow poll folds the same
  way. Apple agrees: the pinning plist's alias for one Sportsball! row points
  at the other row's original group id.
- **Group photos, and no more borrowed faces.** A group row bound its
  picture to whoever spoke last, so it showed that member's cached contact
  photo one minute and initials the next. Groups now bind to their own chat
  id and the bridge streams the group's own photo (`imsg avatar --chat <id>`,
  PNG/JPEG as-is, anything else through sips). Messages keeps that photo as
  an attachment whose name ends in `GroupPhotoImage`; the carrier message's
  `group_action_type` is 3 for photos set up to April 2025 and 1 after, so
  the lookup matches the FILENAME, not the action type, and searches every
  chat row of the conversation — a re-keyed group can keep its photo on the
  row Messages retired. Groups without one show initials.
- **"No photo" is remembered for a day, not a week.** A photo that appears
  later — a new group picture, a Contacts card, or a bridge fix that starts
  finding one — now shows up within a day instead of after the 7-day cache
  expired.
- **Every link gets its card, not just the ones Apple decorated.** Messages
  builds an `LPLinkMetadata` preview for some URLs and leaves most bare — on
  this Mac 7 of 27. For the bare ones Blip now fetches the page itself and
  builds the same card from its Open Graph tags: picture, title, description,
  host. The fetch happens on the Linux box, never the Mac; http(s) only, at
  most three redirects, and a host resolving into your LAN or to a cloud
  metadata address is refused, so a link from a stranger cannot make Blip
  probe your network. Cached for a week (a page with no card, for a day) under
  `~/.cache/blip/linkpreview`. `link_previews=off` in `bridge.conf` turns it
  off. A message that is only a URL shows just the card, like Messages.
- **The share sheet opens itself for a link, sent or received.** Send a
  message containing a URL and the sheet comes up on it; a link that ARRIVES
  does the same — but only onto a Blip surface that is already open, because
  Omarchy runs `focus_on_activate=false` and a bank alert must not throw a
  panel over full-screen work. One sheet, the newest link only, and each
  message fires exactly once through a persisted `link:` ring, so a catch-up
  after sleep cannot stack modals and yesterday's links never pop tomorrow.
  The self-thread never triggers it.
- **Open the app from the panel.** A ⇱ button beside ＋ in the panel header
  opens the full app window, the same thing SUPER+M does.
- **Share sheet for links.** Right-click a link in a bubble, or a link card,
  and Blip opens a sheet: open in browser, copy, a QR code your phone can
  scan, and "send to a device" through LocalSend — Omarchy's own share sheet,
  fed the way `omarchy-menu-share clipboard` feeds it. The URL travels on
  stdin to qrencode and to the temp file; left-click still opens the link.
- **Pinned conversations, mirrored from Messages.** The Mac's ordered pin
  list (`com.apple.messages.pinning.plist`, `pD.pP`) rides along on the
  `chats` call and Blip renders those conversations as avatar tiles above the
  list, in Messages' order. Read-only: Blip has no pin control and writes
  nothing back. (Erik Zachrisen, #11) Follow-ups on main: groups are pinned
  by their chat.db `group_id` / `original_group_id`, not the chat identifier,
  so pinned groups resolve too; the reader uses the ordered list (with the
  `pZ` alias map) instead of every string in the file, which had ranked a
  group ahead of every DM; and j/k highlight a pinned tile — the cursor walks
  pinned threads first and had no visible position on them.

## 2.2.3 — 2026-09-02

- **Received bubbles showed a lighter square in the tail corner.** The
  "tail" was a second translucent rectangle drawn over the corner, so the
  14 % fill composited twice. The corner is now squared with Qt 6.7
  per-corner radii and the extra rectangle is gone. (Adam Gamble, #10)
- **iPhone photos rendered on their side — inline AND in the viewer.** A
  camera photo stores its rotation as an EXIF orientation tag, and `sips`
  keeps that tag when the bridge converts HEIC to JPEG — so the pixels
  arrive landscape with a "rotate 90°" note that Qt only honours on request
  and imv (Omarchy's default viewer) never does. Two fixes: every `Image` in
  the conversation sets `autoTransform: true`, and `fetch.ts` now bakes the
  orientation into the cached JPEG losslessly with `jpegtran` (libjpeg-turbo,
  already on every Qt box) — colour profile kept, EXIF dropped so nothing
  double-rotates. Files cached before this release stay as they were; clear
  `~/.cache/blip/att` to re-fetch them upright. (Adam Gamble, #9)

## 2.2.2 — 2026-09-02

- **Group sends failed with -1728 on Macs that keep one chat row per
  service.** A group that moved between iMessage, SMS and RCS leaves several
  `chat` rows sharing one identifier; only one holds messages. `imsg groups`
  returned all of them, the empty shell sorted last and overwrote the live
  guid in Blip's group cache, and AppleScript could not resolve it. The bridge
  now keeps one row per identifier, newest first. Mac side: re-run the install
  one-liner so `~/.blip/bin/imsg` picks it up. (tolewis, #8)

## 2.2.1 — 2026-09-02

- **Short-code SMS threads opened empty.** Georgia Power (99123), 878478 and
  every other 5–8 digit sender showed in the list but loaded zero bubbles:
  the thread loader's CLI convenience turned any bare digits into an E.164
  number ("+99123"), and 2.2.0's exact chat-id query correctly found nothing.
  Only a full number (10+ digits) is "+"-prefixed now, in `thread.ts` and in
  the IPC `goto` alias. Short codes go through verbatim. Tests for both.
- **App window fills like other Omarchy windows.** The 0.70 backdrop alpha
  assumed Hyprland blur, which stock Omarchy 4.x ships off — the wallpaper
  showed through the Super+M window. Now `color: Color.background`, like the
  shell's dev gallery, with Hyprland's default-opacity rule doing the rest.
  (Johan Thorén, #7)

## 2.2.0 — 2026-09-02 — verified fixes

The war-room judge panel re-ran against 2.1.6 (three lenses per finding):
11 earlier fixes confirmed closed, 17 findings confirmed open. This release
fixes 13 of them; the rest stay listed in ROADMAP.md.

**Multi-monitor.** Omarchy builds one bar — and one Blip widget — per
screen. Only the widget on the first screen now polls, watches, toasts,
owns the app window and answers IPC; the others show the badge from
`state.json` and forward clicks to it. (Previously: N pollers, N ssh
watchers, duplicate toasts and windows.)

**Sends.** SMS/RCS conversations go out on their own service instead of
silently as iMessage (text and files). A refused send now shows the Mac's
reason ("message too long", "not authorized"…) instead of "exit 1".

**Reads.** The app window marks a conversation read only while it is the
focused window — visible on another workspace no longer clears dots.
Mark-all-read / middle-click / IPC refresh keep the full list when a
surface is open (a shallow run used to collapse it to the preview window).

**Correctness.** A DM loads by exact chat id (`thread --chat`) so a
contact's group posts no longer eat the history window. A DM is persisted
as a "self chat" only after two independent same-second twins, not one
coincidence. Failed-send toasts fired every poll for 15 minutes because the
dedupe ring dropped their `fail:` prefix on load.

**Robustness.** A `bun` that cannot start is reported as such (not "Mac
unreachable"); the offline poll backs off to 30 s; the push watcher's
liveness timer arms at start.

**Config.** `country_code=` in `bridge.conf` for numbers typed without a
country code outside North America.

**Docs.** README no longer promises a headless Mac without a logged-in
session; the last real-looking number left the code; a duplicated README
block removed.

## 2.1.6 — 2026-09-01

- **Duplicate toasts fixed.** The bridge now emits each message's ROWID and
  the toast key no longer includes the text: Messages can land a row before
  its decoded body, and a timestamp slightly ahead of the Linux clock kept
  the message above the watermark, so the same message toasted twice.

## 2.1.1 – 2.1.4 — 2026-09-01

- **Links open and come to the front.** Clicks were reaching `xdg-open`
  all along; Omarchy's `focus_on_activate=false` left the tab on the
  browser's workspace. Blip now focuses the browser after opening. (2.1.4)
- **Text selection + Ctrl+C in bubbles** — the conversation Flickable was
  grabbing every drag. (2.1.1)
- **Contact names regression** — one person across several Contacts
  sources ("Rob" / "Robert") is not a collision. (2.1.2)
- Repo scrubbed of maintainer machine names, a real group name, absolute
  paths. (2.1.3)
- README Install rewritten around `omarchy plugin add … --enable`, with
  notes for humans and for AI agents; `AGENTS.md` added. (2.1.4)

## 2.1.0 — 2026-09-01 — war room

Ten expert-lens reviewers swept the repo after the DHH retweet; 114
findings, the clear ones fixed here, the rest on the roadmap.

**Fixed — correctness**
- Attachment-cache eviction had silently never run since 1.9.4 (a missing
  `statSync` import threw inside the LRU). 500 MB cap is real again.
- A DM thread admitted that person's messages from *group* chats.
- Catch-up fetches could exceed Bun's default 1 MB `spawnSync` buffer and
  fail sticky; all bridge calls now allow 64 MB.
- A timed-out `imsg` (Mac asleep behind a live ssh mux) read as a bridge
  bug; it now reads as "Mac asleep" and greys the icon.
- Bridge errors show the *last* stderr line (Python puts the cause last),
  not "Traceback (most recent call last):".
- `state.json` is fsync'd before rename (a power cut no longer resets every
  read mark). Cache temp names carry entropy (no EEXIST after pid reuse).
- Link cards: `$null` titles, URLs with `(…)` (Wikipedia), and userinfo
  host-spoofing handled. Inline-reply snippets respect Recently Deleted.
- macOS 12 and earlier: `imsg` no longer dies on the missing
  Recently-Deleted table.
- Avatar initials for whitespace-only names; non-ASCII attachment names
  survive sanitizing; sent files keep their extension.
- `wait_for_copy` matches only attachment rows newer than the send
  (same-name re-sends no longer confuse it); a send whose copy was never
  observed is kept in `~/.blip/sent` instead of deleted an hour later.

**Fixed — security / privacy**
- File-send captions no longer appear in any process's argv
  (`--caption-stdin`). A cut ssh stream can no longer deliver a truncated
  file (`--file-bytes N` is enforced on the Mac).
- Cache file extensions follow the gated MIME type, not the sender's
  filename (`xdg-open` dispatches on extension).
- `tcc-check` removed from the confined key's allowlist.
- `blip-setup` no longer `source`s `bridge.conf`, no longer echoes a message
  body into the terminal, guards the `authorized_keys` append with a
  newline, keeps a hand-set `automation=` on re-run, drops the ssh master
  before re-checking grants, and names a missing Xcode CLT instead of
  misdiagnosing Full Disk Access. `install.sh` fails loudly on the CLT stub.
- Consent banner prints only on a TTY (recipients no longer reach journald).
- A real phone number and email were removed from a public test fixture.
- Transient bridge failures no longer write a 7-day "no photo" marker.

**Changed**
- Users' dashes are sent as typed (`--keep-dashes` everywhere).
- `xdg-open` and the window-state writer run detached (a blocking handler
  or a mid-write hide could swallow later clicks / the hidden state).
- IPC `compose` refuses when the popout is closed.
- The shim's offline message includes the ssh reason.
- `sync-bridge.sh` stages upstream copies beside locally-modified tools
  instead of overwriting them.
- Tests are isolated from the developer's real caches (`bunfig.toml`
  preload sets `XDG_CACHE_HOME`).

## 2.0.4 — 2026-09-01

**Fixed**
- `blip-check` probed a single, unordered Contacts source; a stale CardDAV
  `.abcddb` sorting first produced a false "contacts ❌ — grant Full Disk
  Access" during `blip-setup` even though contacts and avatars worked. It now
  probes every source like the `contacts` tool does and fails only when none
  opens. First outside contribution — **@jethrojones** (#2). Thank you.

**Repo**
- CI on every push and PR (bun test, Mac tools byte-compile, shellcheck),
  CONTRIBUTING, issue/PR templates, security policy, GitHub Releases.
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
