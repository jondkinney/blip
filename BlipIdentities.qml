import QtQuick
import Quickshell
import Quickshell.Io

// Short-lived, bounded bridge between the settings UI and identities.ts.
// No writable contact/config file is parsed inside the shell process.
Item {
  id: root
  visible: false
  implicitWidth: 0
  implicitHeight: 0

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/blip/identities.json"
  readonly property string helperPath:
    decodeURIComponent(Qt.resolvedUrl("identities.ts").toString().replace(/^file:\/\//, ""))

  property var identities: []
  property var candidates: []
  property var repairPreview: null
  property var comparison: null
  property var linkPreview: null
  property string comparisonOwnerToken: ""
  property string activeHandle: ""
  property bool contactWrites: false
  property string pendingRepairToken: ""
  property string pendingOwnerToken: ""
  property string undoToken: ""
  property string undoHandle: ""
  property string undoName: ""
  property int undoFieldCount: 0
  property bool loaded: false
  property bool loading: false
  property string error: ""
  property string notice: "Loading contact choices…"
  property string currentOperation: ""
  property bool reloadAfterExit: false
  property bool readSilently: false
  property string identitiesJson: ""
  property string pendingReviewHandle: ""
  property bool refreshCandidatesAfterExit: false

  signal choicesChanged()

  function safeText(value, maximum) {
    if (typeof value !== "string" || value.length > maximum) return ""
    return value
      .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ")
      .replace(/\s+/g, " ").trim()
  }

  function safeError(value) {
    return safeText(String(value || "Contact-name operation failed"), 180)
      || "Contact-name operation failed"
  }

  function validToken(value) {
    return typeof value === "string" && /^sha256:[0-9a-f]{64}$/.test(value)
  }

  function safeIdentity(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    var handle = safeText(value.handle, 320)
    var name = safeText(value.name, 160)
    var source = value.source === "contacts" ? "contacts" : value.source === "custom" ? "custom" : ""
    if (handle === "" || name === "" || source === "") return null
    var result = { handle: handle, name: name, source: source, contactToken: "" }
    if (source === "contacts") {
      if (!validToken(value.contactToken)) return null
      result.contactToken = value.contactToken
    }
    return result
  }

  function safeCandidate(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    var name = safeText(value.name, 160)
    var records = Number(value.recordCount)
    var sources = Number(value.sourceCount)
    if (name === "" || !validToken(value.token)
        || !Number.isInteger(records) || records < 1 || records > 64
        || !Number.isInteger(sources) || sources < 1 || sources > 64) return null
    if (!Array.isArray(value.cards) || value.cards.length !== records) return null
    var cards = []
    var accounts = ({})
    var tokens = ({})
    tokens[value.token] = true
    for (var i = 0; i < value.cards.length; i++) {
      var rawCard = value.cards[i]
      if (!rawCard || typeof rawCard !== "object" || Array.isArray(rawCard)
          || !validToken(rawCard.token) || tokens[rawCard.token]) return null
      var account = Number(rawCard.accountNumber)
      if (!Number.isInteger(account) || account < 1 || account > 64) return null
      tokens[rawCard.token] = true
      accounts[account] = true
      cards.push({
        token: rawCard.token,
        accountNumber: account,
        hasPhoto: rawCard.hasPhoto === true,
        matchCount: Number.isInteger(Number(rawCard.matchCount))
          && Number(rawCard.matchCount) >= 1 && Number(rawCard.matchCount) <= 8
          ? Number(rawCard.matchCount) : 1
      })
    }
    if (Object.keys(accounts).length !== sources) return null
    return {
      token: value.token,
      name: name,
      recordCount: records,
      sourceCount: sources,
      hasPhoto: value.hasPhoto === true,
      cards: cards
    }
  }

  function safeRepairPreview(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    var handle = safeText(value.handle, 320)
    var name = safeText(value.name, 160)
    var kind = value.kind === "phone" ? "phone" : value.kind === "email" ? "email" : ""
    var fieldCount = Number(value.fieldCount)
    var cardNumber = Number(value.cardNumber)
    var cardCount = Number(value.cardCount)
    var accountNumber = Number(value.accountNumber)
    if (handle === "" || name === "" || kind === ""
        || !Number.isInteger(fieldCount) || fieldCount < 1 || fieldCount > 8
        || !Number.isInteger(cardNumber) || cardNumber < 1 || cardNumber > 64
        || !Number.isInteger(cardCount) || cardCount < cardNumber || cardCount > 64
        || !Number.isInteger(accountNumber) || accountNumber < 1 || accountNumber > 64
        || !Array.isArray(value.labels) || value.labels.length !== fieldCount) return null
    var labels = []
    for (var i = 0; i < value.labels.length; i++) {
      if (typeof value.labels[i] !== "string" || value.labels[i].length > 80) return null
      labels.push(safeText(value.labels[i], 80))
    }
    return {
      handle: handle, name: name, kind: kind, fieldCount: fieldCount,
      labels: labels, cardNumber: cardNumber, cardCount: cardCount,
      accountNumber: accountNumber, writeEnabled: value.writeEnabled === true,
      token: pendingRepairToken, ownerToken: pendingOwnerToken
    }
  }

  function safeOptionalText(value, maximum) {
    if (typeof value !== "string" || value.length > maximum) return null
    return value
      .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ")
      .replace(/\s+/g, " ").trim()
  }

  function safeLabeledValues(value) {
    if (!Array.isArray(value) || value.length > 16) return null
    var result = []
    for (var i = 0; i < value.length; i++) {
      var item = value[i]
      if (!item || typeof item !== "object" || Array.isArray(item)) return null
      var label = safeOptionalText(item.label, 80)
      var itemValue = safeOptionalText(item.value, 320)
      if (label === null || itemValue === null || itemValue === "") return null
      result.push({ label: label, value: itemValue })
    }
    return result
  }

  function safeAddresses(value) {
    if (!Array.isArray(value) || value.length > 16) return null
    var result = []
    var keys = ["label", "street", "city", "state", "postalCode", "country", "countryCode"]
    var limits = [80, 320, 320, 320, 80, 160, 8]
    for (var i = 0; i < value.length; i++) {
      var item = value[i]
      if (!item || typeof item !== "object" || Array.isArray(item)) return null
      var address = ({})
      for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
        var cleaned = safeOptionalText(item[keys[keyIndex]], limits[keyIndex])
        if (cleaned === null) return null
        address[keys[keyIndex]] = cleaned
      }
      if (address.street === "" && address.city === "" && address.state === ""
          && address.postalCode === "" && address.country === "") return null
      result.push(address)
    }
    return result
  }

  function safeComparisonCard(value, expectedNumber, seenTokens) {
    if (!value || typeof value !== "object" || Array.isArray(value) || !validToken(value.token)
        || seenTokens[value.token]) return null
    var cardNumber = Number(value.cardNumber)
    var accountNumber = Number(value.accountNumber)
    if (!Number.isInteger(cardNumber) || cardNumber !== expectedNumber
        || !Number.isInteger(accountNumber) || accountNumber < 1 || accountNumber > 64) return null
    var scalarKeys = ["displayName", "firstName", "middleName", "lastName", "nickname",
      "organization", "department", "jobTitle", "birthday", "note"]
    var scalarLimits = [160, 160, 160, 160, 160, 320, 320, 320, 10, 1000]
    var card = ({ token: value.token, cardNumber: cardNumber, accountNumber: accountNumber,
      hasPhoto: value.hasPhoto === true })
    seenTokens[value.token] = true
    for (var i = 0; i < scalarKeys.length; i++) {
      var text = safeOptionalText(value[scalarKeys[i]], scalarLimits[i])
      if (text === null) return null
      card[scalarKeys[i]] = text
    }
    if (card.birthday !== "" && !/^(?:[0-9]{4}\-|--)[0-9]{2}\-[0-9]{2}$/.test(card.birthday)) return null
    card.phones = safeLabeledValues(value.phones)
    card.emails = safeLabeledValues(value.emails)
    card.urls = safeLabeledValues(value.urls)
    card.addresses = safeAddresses(value.addresses)
    if (card.phones === null || card.emails === null || card.urls === null || card.addresses === null)
      return null
    return card
  }

  function safeComparison(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    var handle = safeText(value.handle, 320)
    var name = safeText(value.name, 160)
    var cardCount = Number(value.cardCount)
    var sourceCount = Number(value.sourceCount)
    if (handle === "" || name === "" || !Number.isInteger(cardCount) || cardCount < 2 || cardCount > 8
        || !Number.isInteger(sourceCount) || sourceCount < 1 || sourceCount > 8
        || !Array.isArray(value.cards) || value.cards.length !== cardCount) return null
    var seen = ({})
    var accounts = ({})
    var cards = []
    for (var i = 0; i < value.cards.length; i++) {
      var card = safeComparisonCard(value.cards[i], i + 1, seen)
      if (!card) return null
      accounts[card.accountNumber] = true
      cards.push(card)
    }
    if (Object.keys(accounts).length !== sourceCount) return null
    return { handle: handle, name: name, cardCount: cardCount, sourceCount: sourceCount,
      writeEnabled: value.writeEnabled === true, cards: cards, ownerToken: comparisonOwnerToken }
  }

  function safeLinkPreview(value, requireLinked) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    var handle = safeText(value.handle, 320)
    var name = safeText(value.name, 160)
    var cardCount = Number(value.cardCount)
    var sourceCount = Number(value.sourceCount)
    var action = safeText(value.action, 80)
    if (handle === "" || name === "" || !Number.isInteger(cardCount) || cardCount < 2 || cardCount > 8
        || !Number.isInteger(sourceCount) || sourceCount < 1 || sourceCount > 8
        || ["Link Selected Cards", "Merge Selected Cards", "Merge and Link Selected Cards"].indexOf(action) < 0)
      return null
    if (requireLinked === true && value.linked !== true) return null
    if (requireLinked !== true && typeof value.ready !== "boolean") return null
    return { handle: handle, name: name, cardCount: cardCount, sourceCount: sourceCount,
      writeEnabled: value.writeEnabled === true, action: action,
      ready: requireLinked === true ? false : value.ready, linked: value.linked === true }
  }

  function validatedList(value, validator, maximum) {
    if (!Array.isArray(value) || value.length > maximum) return null
    var result = []
    for (var i = 0; i < value.length; i++) {
      var item = validator(value[i])
      if (!item) return null
      result.push(item)
    }
    return result
  }

  function start(operation, payload, quiet) {
    if (worker.running) return false
    error = ""
    currentOperation = operation
    reloadAfterExit = false
    refreshCandidatesAfterExit = false
    // A periodic read is bookkeeping, not a visible operation. Toggling
    // `loading` here used to disable and repaint every settings row at 5 s.
    loading = quiet !== true
    worker.payload = payload === undefined ? "" : JSON.stringify(payload)
    worker.stdinEnabled = worker.payload !== ""
    worker.command = ["bun", helperPath, operation]
    worker.running = true
    return true
  }

  function load(silent) {
    readSilently = silent === true
    return start("read", undefined, readSilently && loaded)
  }

  function findCandidates(handle) {
    var requested = safeText(String(handle || ""), 320)
    if (requested === "") return false
    // A click that lands during the tiny local-file refresh window must not
    // be lost. Finish that read, then begin the user-visible Mac lookup.
    if (worker.running) {
      if (currentOperation === "read" && readSilently) {
        pendingReviewHandle = requested
        return true
      }
      return false
    }
    activeHandle = requested
    candidates = []
    repairPreview = null
    comparison = null
    linkPreview = null
    comparisonOwnerToken = ""
    pendingRepairToken = ""
    pendingOwnerToken = ""
    notice = "Checking matching cards on the Mac…"
    return start("candidates", { handle: activeHandle }, false)
  }

  function dismissReview() {
    if (worker.running) return false
    activeHandle = ""
    candidates = []
    repairPreview = null
    comparison = null
    linkPreview = null
    comparisonOwnerToken = ""
    pendingRepairToken = ""
    pendingOwnerToken = ""
    error = ""
    notice = identities.length === 0 ? "No saved contact choices" : "Loaded saved contact choices"
    return true
  }

  function choose(handle, name, token) {
    notice = "Saving a Blip-only display name…"
    return start("choose", { handle: handle, name: name, token: token })
  }

  function setCustom(handle, name) {
    notice = "Saving custom name…"
    return start("custom", { handle: handle, name: name })
  }

  function clearChoice(handle) {
    notice = "Removing the Blip-only override…"
    return start("clear", { handle: handle })
  }

  function openOnMac(handle, token) {
    notice = "Opening one Contacts card on the Mac; no data will be changed…"
    return start("open", { handle: handle, token: token })
  }

  function compareCards(handle, ownerToken) {
    if (!validToken(ownerToken)) return false
    comparison = null
    linkPreview = null
    comparisonOwnerToken = ownerToken
    notice = "Loading the active card details from Contacts…"
    return start("compare", { handle: handle, ownerToken: ownerToken })
  }

  function prepareLink() {
    if (!contactWrites || !comparison || !comparison.writeEnabled
        || !validToken(comparison.ownerToken)) return false
    linkPreview = null
    notice = "Selecting the exact cards and checking Apple’s link action…"
    return start("link-prepare", {
      handle: comparison.handle, ownerToken: comparison.ownerToken
    })
  }

  function linkCards() {
    if (!contactWrites || !comparison || !linkPreview || !linkPreview.ready
        || !linkPreview.writeEnabled || !validToken(comparison.ownerToken)) return false
    notice = "Running Contacts’ verified “" + linkPreview.action + "” action…"
    return start("link", { handle: comparison.handle, ownerToken: comparison.ownerToken,
      expectedAction: linkPreview.action })
  }

  function cancelLink() {
    if (worker.running) return false
    linkPreview = null
    notice = "No Contacts data was changed"
    return true
  }

  function cancelComparison() {
    if (worker.running) return false
    comparison = null
    linkPreview = null
    comparisonOwnerToken = ""
    notice = candidates.length > 1 ? "Contacts has conflicting names" : "Contacts has one matching name"
    return true
  }

  function inspectOnMac(handle, token, ownerToken) {
    if (!contactWrites || !validToken(token) || !validToken(ownerToken) || token === ownerToken)
      return false
    pendingRepairToken = token
    pendingOwnerToken = ownerToken
    repairPreview = null
    notice = "Verifying the exact field with Contacts on the Mac…"
    return start("inspect", { handle: handle, token: token, ownerToken: ownerToken })
  }

  function cancelRepair() {
    if (worker.running) return false
    repairPreview = null
    pendingRepairToken = ""
    pendingOwnerToken = ""
    notice = candidates.length > 1 ? "Contacts has conflicting names" : "Contacts has one matching name"
    return true
  }

  function removeOnMac() {
    if (!contactWrites || !repairPreview || !repairPreview.writeEnabled
        || !validToken(repairPreview.token)
        || !validToken(repairPreview.ownerToken)) return false
    notice = "Removing the verified field from Mac Contacts…"
    return start("remove", {
      handle: repairPreview.handle, token: repairPreview.token,
      ownerToken: repairPreview.ownerToken
    })
  }

  function undoOnMac() {
    if (!contactWrites || !/^undo:[0-9a-f]{32}$/.test(undoToken)) return false
    notice = "Restoring the removed field in Mac Contacts…"
    return start("undo", { undoToken: undoToken })
  }

  function consume(raw) {
    if (raw.length > 49152) {
      error = "Identity helper returned too much data"
      return
    }
    var result
    try { result = JSON.parse(raw.trim()) }
    catch (e) {
      error = "Identity helper returned invalid JSON"
      return
    }
    if (!result || result.ok !== true) {
      error = safeError(result ? result.error : "Identity helper failed")
      return
    }
    if (currentOperation === "read") {
      var saved = validatedList(result.identities, function(value) { return root.safeIdentity(value) }, 64)
      if (saved === null) { error = "Identity helper returned an invalid saved-choice list"; return }
      var serialized = JSON.stringify(saved)
      // A QML array assignment rebuilds every Repeater delegate, even when
      // the rows are identical. Preserve the existing model on no-op polls.
      if (serialized !== identitiesJson) {
        identitiesJson = serialized
        identities = saved
      }
      contactWrites = result.contactWrites === true
      loaded = true
      if (!readSilently)
        notice = saved.length === 0 ? "No saved contact choices" : "Loaded saved contact choices"
      return
    }
    if (currentOperation === "candidates") {
      var options = validatedList(result.candidates, function(value) { return root.safeCandidate(value) }, 8)
      var handle = safeText(result.handle, 320)
      if (options === null || handle === "") {
        error = "Identity helper returned an invalid candidate list"
        return
      }
      var totalCards = 0
      var allTokens = ({})
      for (var candidateIndex = 0; candidateIndex < options.length; candidateIndex++) {
        var option = options[candidateIndex]
        if (allTokens[option.token]) { error = "Identity helper returned duplicate contact tokens"; return }
        allTokens[option.token] = true
        totalCards += option.cards.length
        for (var cardIndex = 0; cardIndex < option.cards.length; cardIndex++) {
          var cardToken = option.cards[cardIndex].token
          if (allTokens[cardToken]) { error = "Identity helper returned duplicate contact tokens"; return }
          allTokens[cardToken] = true
        }
      }
      if (totalCards > 64) { error = "Identity helper returned too many contact cards"; return }
      activeHandle = handle
      candidates = options
      notice = options.length === 0
        ? "No matching contact cards were found"
        : options.length === 1 ? "Contacts has one matching name" : "Contacts has conflicting names"
      return
    }
    if (currentOperation === "choose" || currentOperation === "custom") {
      var identity = safeIdentity(result.identity)
      if (!identity) { error = "Identity helper returned an invalid saved choice"; return }
      notice = "Saved “" + identity.name + "” in Blip only; Mac Contacts was not changed"
      reloadAfterExit = true
      choicesChanged()
      return
    }
    if (currentOperation === "clear") {
      var after = validatedList(result.identities, function(value) { return root.safeIdentity(value) }, 64)
      if (after === null) { error = "Identity helper returned an invalid saved-choice list"; return }
      identitiesJson = JSON.stringify(after)
      identities = after
      notice = "Removed the Blip-only name"
      choicesChanged()
      return
    }
    if (currentOperation === "open") {
      var openedName = safeText(result.name, 160)
      var openedCard = Number(result.cardNumber)
      var openedCount = Number(result.cardCount)
      var openedAccount = Number(result.accountNumber)
      if (result.opened !== true || openedName === ""
          || !Number.isInteger(openedCard) || openedCard < 1 || openedCard > 64
          || !Number.isInteger(openedCount) || openedCount < 1 || openedCount > 64
          || openedCard > openedCount
          || !Number.isInteger(openedAccount) || openedAccount < 1 || openedAccount > 64) {
        error = "Contacts.app did not open the selected card"
        return
      }
      notice = "Opened “" + openedName + "” card " + openedCard + " of " + openedCount
        + " in Contacts on the Mac. Nothing was changed."
      return
    }
    if (currentOperation === "compare") {
      var compared = safeComparison(result.comparison)
      if (!compared || !validToken(compared.ownerToken)) {
        error = "Contacts returned an invalid card comparison"
        return
      }
      comparison = compared
      linkPreview = null
      notice = "Loaded " + compared.cardCount + " active cards for comparison; nothing was changed"
      return
    }
    if (currentOperation === "link-prepare") {
      var prepared = safeLinkPreview(result.preview, false)
      if (!prepared || !comparison || prepared.handle !== comparison.handle
          || prepared.cardCount !== comparison.cardCount) {
        error = "Contacts returned an invalid link preview"
        return
      }
      linkPreview = prepared
      notice = prepared.ready
        ? "Contacts is ready; review the final link confirmation"
        : "Contacts does not offer a link for this exact selection; the cards may already be linked"
      return
    }
    if (currentOperation === "link") {
      var linked = safeLinkPreview(result, true)
      if (!linked || !comparison || linked.handle !== comparison.handle
          || linked.cardCount !== comparison.cardCount) {
        error = "Contacts did not confirm the link action"
        return
      }
      notice = "Contacts ran “" + linked.action + "” for the exact " + linked.cardCount + " cards"
      comparison = null
      linkPreview = null
      comparisonOwnerToken = ""
      refreshCandidatesAfterExit = true
      return
    }
    if (currentOperation === "inspect") {
      var preview = safeRepairPreview(result.preview)
      if (!preview || !validToken(preview.token)) {
        error = "Contacts returned an invalid repair preview"
        return
      }
      repairPreview = preview
      notice = preview.writeEnabled
        ? "Verified the exact Mac Contacts field; review the confirmation below"
        : "The Mac-side contact-writes gate is disabled"
      return
    }
    if (currentOperation === "remove") {
      var removedPreview = safeRepairPreview(result)
      var returnedUndo = safeText(result.undoToken, 40)
      if (!removedPreview || result.removed !== true || !/^undo:[0-9a-f]{32}$/.test(returnedUndo)) {
        error = "Contacts did not confirm the removal"
        return
      }
      undoToken = returnedUndo
      undoHandle = removedPreview.handle
      undoName = removedPreview.name
      undoFieldCount = removedPreview.fieldCount
      repairPreview = null
      pendingRepairToken = ""
      pendingOwnerToken = ""
      notice = "Removed the verified " + removedPreview.kind + " from “" + removedPreview.name + "” on the Mac"
      refreshCandidatesAfterExit = true
      return
    }
    if (currentOperation === "undo") {
      var restoredHandle = safeText(result.handle, 320)
      var restoredName = safeText(result.name, 160)
      var restoredCount = Number(result.fieldCount)
      if (result.restored !== true || restoredHandle === "" || restoredName === ""
          || !Number.isInteger(restoredCount) || restoredCount < 1 || restoredCount > 8) {
        error = "Contacts did not confirm the restore"
        return
      }
      undoToken = ""
      undoHandle = ""
      undoName = ""
      undoFieldCount = 0
      notice = result.alreadyPresent === true
        ? "The field was already present in Mac Contacts"
        : "Restored the field to “" + restoredName + "” on the Mac"
      refreshCandidatesAfterExit = true
    }
  }

  Process {
    id: worker
    property string payload: ""
    stdout: StdioCollector { onStreamFinished: root.consume(text) }
    onStarted: {
      if (payload !== "") write(payload)
      stdinEnabled = false
    }
    onExited: function(code, status) {
      root.loading = false
      if (code !== 0 && root.error === "") root.error = "Contact-name operation failed"
      if (root.pendingReviewHandle !== "") {
        var requested = root.pendingReviewHandle
        root.pendingReviewHandle = ""
        Qt.callLater(function() { root.findCandidates(requested) })
        return
      }
      if (root.refreshCandidatesAfterExit) {
        root.refreshCandidatesAfterExit = false
        var active = root.activeHandle
        if (active !== "") Qt.callLater(function() { root.findCandidates(active) })
        return
      }
      if (root.reloadAfterExit) {
        root.reloadAfterExit = false
        Qt.callLater(function() { root.load(true) })
      }
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: true
    // Source repair is deliberate and stable while open. Only poll the local
    // override file from the overview, and never overlap another operation.
    onTriggered: if (!worker.running && root.activeHandle === "") root.load(true)
  }

  Component.onCompleted: load(false)
}
