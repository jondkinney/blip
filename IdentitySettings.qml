import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Guided contact-name repair. Selecting a candidate is harmless; changing
// Blip and opening/editing a Mac Contacts card are deliberately separate.
ColumnLayout {
  id: root

  property var resolver: null
  property var threads: []
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontScale: 1.0
  property real density: 1.0
  property real cornerScale: 1.0
  property string selectedToken: ""
  property bool macReviewExpanded: false
  readonly property bool editorActive: customField.activeFocus
  readonly property bool reviewActive: resolver && resolver.activeHandle !== ""
  readonly property var savedChoices: resolver ? resolver.identities : []
  readonly property var unresolved: unresolvedThreads(threads)
  readonly property var selectedCandidate: candidateForToken(selectedToken)
  readonly property var activeChoice: choiceForHandle(resolver ? resolver.activeHandle : "")
  readonly property bool selectedChoiceIsSaved: selectedCandidate && activeChoice
    && activeChoice.source === "contacts"
    && activeChoice.contactToken === selectedCandidate.token
    && activeChoice.name === selectedCandidate.name

  spacing: space(10)

  function fontSize(value) { return Math.max(1, Math.round(value * fontScale)) }
  function space(value) { return Math.max(1, Math.round(Style.spaceReal(value) * density)) }
  function corner(value) { return Math.max(0, Math.round(value * cornerScale)) }
  function directHandle(value) {
    var handle = String(value || "")
    return /^\+?[0-9]{5,}$/.test(handle) || /^[^@\s]+@[^@\s]+$/.test(handle)
  }
  function handleKey(value) {
    var handle = String(value || "")
    if (handle.indexOf("@") >= 0) return "email:" + handle.toLowerCase()
    var digits = handle.replace(/\D/g, "")
    return "phone:" + (digits.length >= 10 ? digits.slice(-10) : digits)
  }
  function unresolvedThreads(value) {
    if (!Array.isArray(value)) return []
    var seen = ({})
    var result = []
    for (var i = 0; i < value.length; i++) {
      var thread = value[i]
      if (!thread) continue
      var chat = String(thread.chat || "")
      var handle = String(thread.handle || chat)
      var name = String(thread.name || "")
      if (!directHandle(chat) || (name !== chat && name !== handle && !directHandle(name))) continue
      if (seen[chat]) continue
      seen[chat] = true
      result.push(thread)
    }
    result.sort(function(a, b) {
      var ap = a.pinned === true ? 0 : 1
      var bp = b.pinned === true ? 0 : 1
      if (ap !== bp) return ap - bp
      return String(a.last_ts || "") < String(b.last_ts || "") ? 1 : -1
    })
    return result.slice(0, 12)
  }
  function choiceForHandle(handle) {
    var key = handleKey(handle)
    if (key === "phone:" || key === "email:") return null
    for (var i = 0; i < savedChoices.length; i++) {
      if (handleKey(savedChoices[i].handle) === key) return savedChoices[i]
    }
    return null
  }
  function candidateForToken(token) {
    if (!resolver || token === "") return null
    for (var i = 0; i < resolver.candidates.length; i++) {
      if (resolver.candidates[i].token === token) return resolver.candidates[i]
    }
    return null
  }
  function candidateDetail(candidate) {
    var cards = candidate.recordCount === 1 ? "1 contact card" : candidate.recordCount + " contact cards"
    var accounts = candidate.sourceCount === 1 ? "1 account" : candidate.sourceCount + " accounts"
    return cards + " · " + accounts + (candidate.hasPhoto ? " · has photo" : "")
  }
  function beginReview(handle) {
    if (!resolver || resolver.loading) return
    var saved = choiceForHandle(handle)
    selectedToken = saved && saved.source === "contacts" ? saved.contactToken : ""
    customField.text = saved && saved.source === "custom" ? saved.name : ""
    macReviewExpanded = false
    resolver.findCandidates(handle)
  }
  function closeReview() {
    if (!resolver || resolver.loading) return
    if (resolver.dismissReview()) {
      selectedToken = ""
      customField.text = ""
      macReviewExpanded = false
    }
  }
  function selectCandidate(candidate) {
    if (!candidate || !resolver || resolver.loading) return
    if (resolver.repairPreview) resolver.cancelRepair()
    if (resolver.comparison) resolver.cancelComparison()
    selectedToken = candidate.token
    customField.text = ""
  }

  Connections {
    target: root.resolver
    function onActiveHandleChanged() {
      var saved = root.choiceForHandle(root.resolver.activeHandle)
      root.selectedToken = saved && saved.source === "contacts" ? saved.contactToken : ""
      customField.text = saved && saved.source === "custom" ? saved.name : ""
    }
    function onCandidatesChanged() {
      var saved = root.activeChoice
      if (saved && saved.source === "contacts"
          && root.candidateForToken(saved.contactToken)) {
        root.selectedToken = saved.contactToken
        return
      }
      if (root.selectedToken !== "" && !root.candidateForToken(root.selectedToken))
        root.selectedToken = ""
    }
  }

  ColumnLayout {
    Layout.fillWidth: true
    visible: !root.reviewActive
    spacing: root.space(10)

  Text {
    Layout.fillWidth: true
    text: "Blip display names and Mac Contacts are two separate layers. Review a conversation, select a person, then explicitly save that display name in Blip. Mac repair is optional, verifies an exact card first, and changes Contacts only after a separate confirmation."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.foreground, 1.35)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.bodySmall)
  }

  Text {
    Layout.fillWidth: true
    visible: root.savedChoices.length > 0
    text: "BLIP-ONLY DISPLAY OVERRIDES"
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.25)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
    font.bold: true
  }

  Repeater {
    model: root.savedChoices
    delegate: Rectangle {
      required property var modelData
      Layout.fillWidth: true
      implicitHeight: savedRow.implicitHeight + root.space(16)
      radius: root.corner(root.space(10))
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

      RowLayout {
        id: savedRow
        anchors.fill: parent
        anchors.margins: root.space(8)
        spacing: root.space(8)
        ColumnLayout {
          Layout.fillWidth: true
          spacing: root.space(2)
          Text {
            Layout.fillWidth: true
            text: String(modelData.name || "")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.bodySmall)
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: String(modelData.handle || "") + " · saved in Blip only · Mac Contacts unchanged"
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
        }
        SmallButton {
          label: "Review names…"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.beginReview(modelData.handle)
        }
        SmallButton {
          label: "Remove Blip override"
          danger: true
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.resolver.clearChoice(modelData.handle)
        }
      }
    }
  }

  Text {
    Layout.fillWidth: true
    visible: root.unresolved.length > 0
    text: "NEEDS A DISPLAY NAME"
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.25)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
    font.bold: true
  }

  Repeater {
    model: root.unresolved
    delegate: RowLayout {
      required property var modelData
      Layout.fillWidth: true
      spacing: root.space(8)
      Text {
        Layout.fillWidth: true
        text: String(modelData.chat || "") + (modelData.pinned === true ? " · Pinned" : "")
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.bodySmall)
      }
      SmallButton {
        label: "Review names…"
        enabled: root.resolver && !root.resolver.loading
        onClicked: root.beginReview(modelData.chat)
      }
    }
  }

  Text {
    Layout.fillWidth: true
    visible: root.savedChoices.length === 0 && root.unresolved.length === 0
    text: root.resolver && !root.resolver.loaded ? "Loading contact names…" : "No unresolved direct conversations."
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.bodySmall)
  }
  }

  Rectangle {
    Layout.fillWidth: true
    visible: root.resolver && root.resolver.activeHandle !== ""
    implicitHeight: guide.implicitHeight + root.space(24)
    radius: root.corner(root.space(12))
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.07)
    border.width: 1
    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)

    ColumnLayout {
      id: guide
      anchors.fill: parent
      anchors.margins: root.space(12)
      spacing: root.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        SmallButton {
          label: "← All conversations"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.closeReview()
        }
        Text {
          Layout.fillWidth: true
          text: "Naming " + String(root.resolver ? root.resolver.activeHandle : "")
          textFormat: Text.PlainText
          elide: Text.ElideMiddle
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.fontSize(Style.font.body)
          font.bold: true
        }
      }

      SectionHeading { label: "1 · CHOOSE WHAT BLIP DISPLAYS" }

      Text {
        Layout.fillWidth: true
        text: "Selecting a row below changes nothing. After selecting the right person, use the separate save button to write only Blip’s portable identities.json file."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.loading
        text: "Checking Contacts on the Mac…"
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      Repeater {
        model: root.resolver ? root.resolver.candidates : []
        delegate: Rectangle {
          id: candidateBox
          required property var modelData
          readonly property bool selected: root.selectedToken === modelData.token
          Layout.fillWidth: true
          implicitHeight: candidateRow.implicitHeight + root.space(16)
          radius: root.corner(root.space(9))
          color: selected
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
          border.width: selected ? 2 : 1
          border.color: selected ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)

          RowLayout {
            id: candidateRow
            anchors.fill: parent
            anchors.margins: root.space(8)
            spacing: root.space(9)
            Rectangle {
              implicitWidth: root.space(16)
              implicitHeight: implicitWidth
              radius: width / 2
              color: candidateBox.selected ? root.accent : "transparent"
              border.width: 2
              border.color: candidateBox.selected ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
              Text {
                anchors.centerIn: parent
                visible: candidateBox.selected
                text: "✓"
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
                font.bold: true
              }
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: root.space(2)
              Text {
                Layout.fillWidth: true
                text: String(modelData.name || "")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.bodySmall)
                font.bold: true
              }
              Text {
                Layout.fillWidth: true
                text: root.candidateDetail(modelData)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
              }
            }
            SmallButton {
              label: candidateBox.selected ? "Selected" : "Select"
              enabled: root.resolver && !root.resolver.loading && !candidateBox.selected
              onClicked: root.selectCandidate(modelData)
            }
          }
          HoverHandler { cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.selectCandidate(modelData) }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && !root.resolver.loading && root.resolver.candidates.length === 0
        text: "No matching Contacts card was found. Add this handle to a person on the Mac, check again, or save a custom Blip-only name below."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      Rectangle {
        Layout.fillWidth: true
        visible: root.selectedCandidate !== null
        implicitHeight: selectedSummary.implicitHeight + root.space(16)
        radius: root.corner(root.space(9))
        color: root.selectedChoiceIsSaved
          ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
        border.width: 2
        border.color: root.selectedChoiceIsSaved
          ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
        ColumnLayout {
          id: selectedSummary
          anchors.fill: parent
          anchors.margins: root.space(8)
          spacing: root.space(5)
          Text {
            Layout.fillWidth: true
            text: root.selectedCandidate
              ? root.selectedChoiceIsSaved
                ? "✓ “" + root.selectedCandidate.name + "” is already saved in Blip"
                : "Ready to save “" + root.selectedCandidate.name + "” in Blip"
              : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.selectedChoiceIsSaved ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.bodySmall)
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: root.selectedChoiceIsSaved
              ? "No save is needed—this is the current Blip display name. Blip did not edit Mac Contacts."
              : "Nothing has changed yet. Saving writes only Blip’s portable identities.json file—not Contacts on the Mac."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
          SmallButton {
            Layout.alignment: Qt.AlignLeft
            visible: !root.selectedChoiceIsSaved
            primary: true
            label: root.selectedCandidate
              ? "Save “" + root.selectedCandidate.name + "” as the Blip display name"
              : "Save selection in Blip"
            enabled: root.resolver && !root.resolver.loading && root.selectedCandidate !== null
            onClicked: root.resolver.choose(
              root.resolver.activeHandle, root.selectedCandidate.name, root.selectedCandidate.token)
          }
          SmallButton {
            Layout.alignment: Qt.AlignLeft
            visible: root.selectedChoiceIsSaved && root.selectedCandidate
              && root.selectedCandidate.recordCount > 1
            primary: true
            label: root.selectedCandidate
              ? "Compare " + root.selectedCandidate.recordCount + " active Contacts cards…"
              : "Compare active Contacts cards…"
            enabled: root.resolver && !root.resolver.loading
            onClicked: {
              root.macReviewExpanded = true
              root.resolver.compareCards(
                root.resolver.activeHandle, root.selectedCandidate.token)
            }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        text: "OR USE A CUSTOM BLIP-ONLY NAME"
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        TextField {
          id: customField
          Layout.fillWidth: true
          placeholderText: "Type a local display name"
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.fontSize(Style.font.bodySmall)
          maximumLength: 160
          onTextChanged: if (activeFocus && text.trim() !== "") root.selectedToken = ""
        }
        SmallButton {
          label: "Save custom name in Blip only"
          enabled: root.resolver && !root.resolver.loading && customField.text.trim() !== ""
          onClicked: root.resolver.setCustom(root.resolver.activeHandle, customField.text)
        }
      }

      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        SectionHeading { label: "2 · REVIEW OR REPAIR MAC CONTACTS · OPTIONAL" }
        SmallButton {
          label: root.macReviewExpanded ? "Hide Contacts tools" : "Review Contacts cards…"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.macReviewExpanded = !root.macReviewExpanded
        }
      }

      Text {
        Layout.fillWidth: true
        text: root.resolver && root.resolver.candidates.length > 1
          ? "The Blip name is handled above. Mac Contacts still has " + root.resolver.candidates.length + " names for this handle; compare or repair the source cards here."
          : "Blip and Contacts agree. You can still compare duplicate active cards, complete their details, or link them through Contacts."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.macReviewExpanded
        spacing: root.space(8)

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.candidates.length > 0 && root.selectedCandidate === null
        text: "Select the correct person in step 1 before deciding which Mac cards to edit."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }

      Repeater {
        model: root.resolver && root.selectedCandidate !== null ? root.resolver.candidates : []
        delegate: Rectangle {
          id: sourceCandidate
          required property var modelData
          readonly property bool intended: root.selectedToken === modelData.token
          property bool cardsExpanded: !intended && modelData.recordCount <= 3
          Layout.fillWidth: true
          implicitHeight: sourceGroup.implicitHeight + root.space(16)
          radius: root.corner(root.space(9))
          color: intended
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.09)
            : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.07)
          border.width: 1
          border.color: intended
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
            : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35)

          ColumnLayout {
            id: sourceGroup
            anchors.fill: parent
            anchors.margins: root.space(8)
            spacing: root.space(6)
            RowLayout {
              Layout.fillWidth: true
              spacing: root.space(8)
              Text {
                Layout.fillWidth: true
                text: (sourceCandidate.intended ? "CORRECT PERSON: " : "WRONG PERSON? ")
                  + String(sourceCandidate.modelData.name || "")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: sourceCandidate.intended ? root.foreground : root.urgent
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
                font.bold: true
              }
              SmallButton {
                visible: sourceCandidate.intended && sourceCandidate.modelData.recordCount > 1
                label: root.resolver && root.resolver.comparison
                  && root.resolver.comparison.ownerToken === sourceCandidate.modelData.token
                  ? "Comparison open"
                  : "Compare & link " + sourceCandidate.modelData.recordCount + " cards…"
                enabled: root.resolver && !root.resolver.loading && root.selectedChoiceIsSaved
                  && (!root.resolver.comparison
                    || root.resolver.comparison.ownerToken !== sourceCandidate.modelData.token)
                onClicked: root.resolver.compareCards(
                  root.resolver.activeHandle, sourceCandidate.modelData.token)
              }
              SmallButton {
                label: sourceCandidate.cardsExpanded
                  ? "Hide cards"
                  : "Show " + sourceCandidate.modelData.recordCount
                    + (sourceCandidate.modelData.recordCount === 1 ? " card" : " cards")
                enabled: root.resolver && !root.resolver.loading
                onClicked: sourceCandidate.cardsExpanded = !sourceCandidate.cardsExpanded
              }
            }
            Text {
              Layout.fillWidth: true
              text: sourceCandidate.intended
                ? "These are the cards for the person you selected. Keep the handle here; merge or link duplicates if appropriate."
                : "If this is a different person, open every listed card and remove only this phone number or email from that person."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.caption)
            }
            Repeater {
              model: sourceCandidate.cardsExpanded ? sourceCandidate.modelData.cards : []
              delegate: RowLayout {
                id: sourceCard
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: root.space(8)
                Text {
                  Layout.fillWidth: true
                  text: "Card " + (sourceCard.index + 1) + " of " + sourceCandidate.modelData.recordCount
                    + " · contact account " + sourceCard.modelData.accountNumber
                    + " of " + sourceCandidate.modelData.sourceCount
                    + (sourceCard.modelData.matchCount > 1
                      ? " · " + sourceCard.modelData.matchCount + " matching fields" : "")
                    + (sourceCard.modelData.hasPhoto ? " · has photo" : "")
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSize(Style.font.caption)
                }
                SmallButton {
                  label: "Open card " + (sourceCard.index + 1) + " on Mac…"
                  enabled: root.resolver && !root.resolver.loading
                  onClicked: root.resolver.openOnMac(root.resolver.activeHandle, sourceCard.modelData.token)
                }
                SmallButton {
                  visible: !sourceCandidate.intended && root.selectedChoiceIsSaved
                    && root.resolver && root.resolver.contactWrites
                  danger: true
                  label: "Remove this handle…"
                  enabled: root.resolver && !root.resolver.loading
                  onClicked: root.resolver.inspectOnMac(
                    root.resolver.activeHandle, sourceCard.modelData.token, root.selectedToken)
                }
              }
            }
          }
        }
      }

      ContactCardCompare {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.comparison !== null
          && root.resolver.comparison.ownerToken === root.selectedToken
        resolver: root.resolver
        comparison: root.resolver ? root.resolver.comparison : null
        foreground: root.foreground
        urgent: root.urgent
        accent: root.accent
        fontFamily: root.fontFamily
        fontScale: root.fontScale
        density: root.density
        cornerScale: root.cornerScale
      }

      Rectangle {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.repairPreview !== null
        implicitHeight: repairConfirmation.implicitHeight + root.space(20)
        radius: root.corner(root.space(9))
        color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.09)
        border.width: 2
        border.color: root.urgent

        ColumnLayout {
          id: repairConfirmation
          anchors.fill: parent
          anchors.margins: root.space(10)
          spacing: root.space(7)
          Text {
            Layout.fillWidth: true
            text: root.resolver && root.resolver.repairPreview
              ? "Remove " + root.resolver.repairPreview.handle + " from “"
                + root.resolver.repairPreview.name + "”?"
              : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.bodySmall)
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: root.resolver && root.resolver.repairPreview
              ? "Verified card " + root.resolver.repairPreview.cardNumber + " of "
                + root.resolver.repairPreview.cardCount + " in contact account "
                + root.resolver.repairPreview.accountNumber + ". This will remove "
                + root.resolver.repairPreview.fieldCount + " matching "
                + root.resolver.repairPreview.kind
                + (root.resolver.repairPreview.fieldCount === 1 ? " field" : " fields")
                + " from synced Mac Contacts. An undo receipt will be saved on the Mac."
              : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
          Text {
            Layout.fillWidth: true
            visible: root.resolver && root.resolver.repairPreview
              && !root.resolver.repairPreview.writeEnabled
            text: "The Mac-side contact-writes gate is disabled. Re-run setup with explicit contact-write access."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
            font.bold: true
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: root.space(8)
            Item { Layout.fillWidth: true }
            SmallButton {
              label: "Cancel"
              enabled: root.resolver && !root.resolver.loading
              onClicked: root.resolver.cancelRepair()
            }
            SmallButton {
              danger: true
              primary: true
              label: "Remove from Mac Contacts"
              enabled: root.resolver && !root.resolver.loading
                && root.resolver.repairPreview && root.resolver.repairPreview.writeEnabled
              onClicked: root.resolver.removeOnMac()
            }
          }
        }
      }

      Rectangle {
        Layout.fillWidth: true
        visible: root.resolver && /^undo:[0-9a-f]{32}$/.test(root.resolver.undoToken)
        implicitHeight: undoContents.implicitHeight + root.space(18)
        radius: root.corner(root.space(9))
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
        border.width: 1
        border.color: root.accent
        RowLayout {
          id: undoContents
          anchors.fill: parent
          anchors.margins: root.space(9)
          spacing: root.space(8)
          Text {
            Layout.fillWidth: true
            text: root.resolver
              ? "Removed " + root.resolver.undoHandle + " from “" + root.resolver.undoName
                + "”. Undo is available here now; its private Mac receipt expires in seven days."
              : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
          SmallButton {
            primary: true
            label: "Undo Mac change"
            enabled: root.resolver && !root.resolver.loading
            onClicked: root.resolver.undoOnMac()
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && !root.resolver.contactWrites
        text: "Automatic contact repair is disabled. Set contact_writes=on locally and enable the separate owner-only gate on the Mac to use it. Opening cards remains read-only."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.contactWrites
          && root.selectedCandidate !== null && !root.selectedChoiceIsSaved
        text: "Save the correct Blip display name in step 1 before contact linking or automatic repair is enabled."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.candidates.length > 0 && root.selectedCandidate !== null
        text: "Opening a card makes no change. Use comparison to see the discovered fields locally, then open an exact card to finish details or prepare Apple’s own link/merge action. Handle removal is separately confirmed and saves an undo receipt."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        SmallButton {
          label: "Check Mac Contacts again"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.resolver.findCandidates(root.resolver.activeHandle)
        }
        SmallButton {
          visible: root.resolver && root.resolver.candidates.length === 1 && root.activeChoice !== null
          label: "Remove portable Blip name"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.resolver.clearChoice(root.resolver.activeHandle)
        }
      }
      }
    }
  }

  Text {
    Layout.fillWidth: true
    visible: root.resolver && (root.resolver.error !== "" || root.resolver.notice !== "")
    text: root.resolver && root.resolver.error !== "" ? root.resolver.error : String(root.resolver ? root.resolver.notice : "")
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.resolver && root.resolver.error !== "" ? root.urgent : Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
  }

  Text {
    Layout.fillWidth: true
    text: root.resolver ? root.resolver.configPath : "~/.config/blip/identities.json"
    textFormat: Text.PlainText
    wrapMode: Text.WrapAnywhere
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
  }

  component SectionHeading: Text {
    property string label: ""
    Layout.fillWidth: true
    text: label
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.2)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
    font.bold: true
  }

  component SmallButton: Rectangle {
    id: button
    property string label: ""
    property bool danger: false
    property bool primary: false
    signal clicked()
    implicitWidth: buttonText.implicitWidth + root.space(16)
    implicitHeight: buttonText.implicitHeight + root.space(10)
    radius: root.corner(root.space(7))
    opacity: enabled ? 1.0 : 0.45
    color: buttonHover.hovered
      ? Qt.rgba((danger ? root.urgent : root.accent).r,
                (danger ? root.urgent : root.accent).g,
                (danger ? root.urgent : root.accent).b, 0.18)
      : primary ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
    border.width: 1
    border.color: danger ? root.urgent : primary ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)
    Text {
      id: buttonText
      anchors.centerIn: parent
      text: button.label
      textFormat: Text.PlainText
      color: button.danger ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontSize(Style.font.caption)
      font.bold: button.primary
    }
    HoverHandler { id: buttonHover; enabled: button.enabled; cursorShape: Qt.PointingHandCursor }
    TapHandler { enabled: button.enabled; onTapped: button.clicked() }
  }
}
