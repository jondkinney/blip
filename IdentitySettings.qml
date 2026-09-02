import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Mac contact management and optional Blip display-name preferences are
// deliberately separate workflows. Selecting a candidate is session-only.
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
  property bool namingExpanded: false
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
    var sources = candidate.sourceCount === 1 ? "1 source" : candidate.sourceCount + " sources"
    return cards + " · " + sources + (candidate.hasPhoto ? " · has photo" : "")
  }
  function beginReview(handle) {
    if (!resolver || resolver.loading) return
    var saved = choiceForHandle(handle)
    selectedToken = saved && saved.source === "contacts" ? saved.contactToken : ""
    customField.text = saved && saved.source === "custom" ? saved.name : ""
    namingExpanded = false
    macReviewExpanded = false
    resolver.findCandidates(handle)
  }
  function openNamePreference() {
    if (!resolver || resolver.loading) return
    if (resolver.comparison) resolver.cancelComparison()
    macReviewExpanded = false
    namingExpanded = true
  }
  function openContactManagement() {
    if (!resolver || resolver.loading || resolver.candidates.length === 0) return
    var candidate = selectedCandidate
    if (!candidate && resolver.candidates.length === 1) {
      selectedToken = resolver.candidates[0].token
      candidate = resolver.candidates[0]
    }
    namingExpanded = false
    macReviewExpanded = true
    if (candidate && (!resolver.comparison
        || resolver.comparison.ownerToken !== candidate.token)) {
      resolver.compareCards(resolver.activeHandle, candidate.token)
    }
  }
  function closeReview() {
    if (!resolver || resolver.loading) return
    if (resolver.dismissReview()) {
      selectedToken = ""
      customField.text = ""
      namingExpanded = false
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
      root.namingExpanded = false
    }
    function onIdentitiesChanged() {
      if (root.choiceForHandle(root.resolver.activeHandle)) root.namingExpanded = false
    }
    function onCandidatesChanged() {
      var saved = root.activeChoice
      if (saved && saved.source === "contacts"
          && root.candidateForToken(saved.contactToken)) {
        root.selectedToken = saved.contactToken
        return
      }
      if (root.selectedToken !== "" && root.candidateForToken(root.selectedToken)) return
      root.selectedToken = root.resolver.candidates.length === 1
        ? root.resolver.candidates[0].token : ""
    }
  }

  ColumnLayout {
    Layout.fillWidth: true
    visible: !root.reviewActive
    spacing: root.space(10)

  Text {
    Layout.fillWidth: true
    text: "Open a conversation to choose one of two separate tasks: manage its Mac contact cards, or save an optional Blip display-name preference. Contact management never creates a naming preference."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.foreground, 1.35)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.bodySmall)
  }

  Text {
    Layout.fillWidth: true
    visible: root.savedChoices.length > 0
    text: "SAVED DISPLAY PREFERENCES"
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
            text: modelData.source === "contacts"
              ? String(modelData.handle || "") + " · From Contacts · contact unchanged"
              : String(modelData.handle || "") + " · custom Blip-only name"
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
        }
        SmallButton {
          label: "Open…"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.beginReview(modelData.handle)
        }
        SmallButton {
          label: modelData.source === "contacts" ? "Stop using name" : "Remove custom name"
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
        label: "Open…"
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
    implicitHeight: guide.implicitHeight + root.space(32)
    radius: root.corner(root.space(12))
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.025)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)

    ColumnLayout {
      id: guide
      anchors.fill: parent
      anchors.margins: root.space(16)
      spacing: root.space(18)

      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        SmallButton {
          label: "← All conversations"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.closeReview()
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: root.space(2)
          Text {
            Layout.fillWidth: true
            text: root.activeChoice ? root.activeChoice.name
              : root.selectedCandidate ? root.selectedCandidate.name : "Conversation contact"
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.body)
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: String(root.resolver ? root.resolver.activeHandle : "")
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.namingExpanded && !root.macReviewExpanded
        text: "What do you want to do? These are separate workflows."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.bodySmall)
      }

      GridLayout {
        Layout.fillWidth: true
        visible: !root.namingExpanded && !root.macReviewExpanded
        columns: width >= root.space(760) ? 2 : 1
        rowSpacing: root.space(12)
        columnSpacing: root.space(12)

        Rectangle {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          implicitHeight: manageTask.implicitHeight + root.space(24)
          radius: root.corner(root.space(10))
          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.1)
          border.width: 1
          border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
          ColumnLayout {
            id: manageTask
            anchors.fill: parent
            anchors.margins: root.space(12)
            spacing: root.space(7)
            Text {
              Layout.fillWidth: true
              text: "MANAGE MAC CONTACTS"
              textFormat: Text.PlainText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.caption)
              font.bold: true
            }
            Text {
              Layout.fillWidth: true
              text: "Deduplicate, merge, edit, delete, or link source cards. This never creates a Blip display-name preference."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.bodySmall)
            }
            SmallButton {
              Layout.alignment: Qt.AlignLeft
              primary: true
              label: root.selectedCandidate && root.selectedCandidate.recordCount > 1
                ? "Manage " + root.selectedCandidate.recordCount + " source cards…"
                : "Manage Contacts…"
              enabled: root.resolver && !root.resolver.loading
                && root.resolver.candidates.length > 0
              onClicked: root.openContactManagement()
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          implicitHeight: namingTask.implicitHeight + root.space(24)
          radius: root.corner(root.space(10))
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
          ColumnLayout {
            id: namingTask
            anchors.fill: parent
            anchors.margins: root.space(12)
            spacing: root.space(7)
            Text {
              Layout.fillWidth: true
              text: "SET A BLIP DISPLAY PREFERENCE · OPTIONAL"
              textFormat: Text.PlainText
              color: Qt.darker(root.foreground, 1.25)
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.caption)
              font.bold: true
            }
            Text {
              Layout.fillWidth: true
              text: root.activeChoice
                ? "Current preference: “" + root.activeChoice.name + "”. Change or remove the portable rule Blip uses for this conversation."
                : "Use only when Blip shows a number or an unwanted name. Skip this when you only want to deduplicate Contacts."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.foreground, 1.3)
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.bodySmall)
            }
            SmallButton {
              Layout.alignment: Qt.AlignLeft
              label: root.activeChoice ? "Change display preference…" : "Choose display name…"
              enabled: root.resolver && !root.resolver.loading
              onClicked: root.openNamePreference()
            }
          }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.namingExpanded
          && (!root.resolver || root.resolver.comparison === null)
        spacing: root.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        SectionHeading { label: "OPTIONAL BLIP DISPLAY NAME" }
        SmallButton {
          visible: root.activeChoice !== null
          danger: true
          label: "Remove display preference"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.resolver.clearChoice(root.resolver.activeHandle)
        }
        SmallButton {
          label: "Back to tasks"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.namingExpanded = false
        }
      }

      Text {
        Layout.fillWidth: true
        text: "This saves a portable rule in identities.json for what Blip displays. It does not edit Mac Contacts, and it is not needed to compare or merge duplicate cards."
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
                ? "✓ Current display preference: “" + root.selectedCandidate.name + "”"
                : "Save “" + root.selectedCandidate.name + "” as Blip’s display preference"
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
              ? "Stored in identities.json. Mac Contacts remains unchanged; remove this preference to return to Blip’s normal contact-name lookup."
              : "This adds a portable name rule for this number. Skip it if your only goal is to deduplicate or edit the contact cards."
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
              ? "Save Contacts name as display preference"
              : "Save Contacts display preference"
            enabled: root.resolver && !root.resolver.loading && root.selectedCandidate !== null
            onClicked: root.resolver.choose(
              root.resolver.activeHandle, root.selectedCandidate.name, root.selectedCandidate.token)
          }
        }
      }

      Text {
        Layout.fillWidth: true
        text: "OR SAVE A CUSTOM BLIP-ONLY DISPLAY NAME"
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

      }

      Rectangle {
        Layout.fillWidth: true
        visible: root.macReviewExpanded
        implicitHeight: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
      }

      RowLayout {
        Layout.fillWidth: true
        visible: root.macReviewExpanded
        spacing: root.space(8)
        SectionHeading { label: "MANAGE MAC CONTACTS" }
        SmallButton {
          label: "Back to tasks"
          enabled: root.resolver && !root.resolver.loading
          onClicked: {
            if (root.resolver.comparison) root.resolver.cancelComparison()
            root.macReviewExpanded = false
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.macReviewExpanded
        text: root.resolver && root.resolver.candidates.length > 1
          ? root.resolver.candidates.length + " people use this handle. Select the person whose cards you want to manage for this session. Nothing is saved as a Blip name."
          : root.selectedCandidate && root.selectedCandidate.recordCount > 1
            ? root.selectedCandidate.recordCount + " source cards found. Compare, edit, consolidate, delete, or link them from Blip."
            : "One source card found. You can review, edit, or delete it from Blip."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.macReviewExpanded
        spacing: root.space(12)

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.candidates.length > 0 && root.selectedCandidate === null
        text: "Select a person below for this contact-management session. This selection is not written to identities.json."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }

      Repeater {
        model: root.resolver ? root.resolver.candidates : []
        delegate: Rectangle {
          id: sourceCandidate
          required property var modelData
          readonly property bool intended: root.selectedToken === modelData.token
          property bool cardsExpanded: !intended && modelData.recordCount <= 3
          visible: !(intended && root.resolver && root.resolver.comparison
            && root.resolver.comparison.ownerToken === modelData.token)
          Layout.fillWidth: true
          implicitHeight: sourceGroup.implicitHeight + root.space(16)
          radius: root.corner(root.space(9))
          color: intended
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.09)
            : root.selectedCandidate
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.07)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          border.width: 1
          border.color: intended
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
            : root.selectedCandidate
              ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)

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
                text: (sourceCandidate.intended ? "SELECTED FOR THIS SESSION: "
                  : root.selectedCandidate ? "OTHER PERSON USING THIS HANDLE: " : "POSSIBLE PERSON: ")
                  + String(sourceCandidate.modelData.name || "")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: sourceCandidate.intended || !root.selectedCandidate
                  ? root.foreground : root.urgent
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
                font.bold: true
              }
              SmallButton {
                label: !sourceCandidate.intended ? "Select for this session"
                  : root.resolver && root.resolver.comparison
                  && root.resolver.comparison.ownerToken === sourceCandidate.modelData.token
                  ? "Contact workspace open"
                  : sourceCandidate.modelData.recordCount === 1 ? "Manage contact…"
                    : "Manage " + sourceCandidate.modelData.recordCount + " cards…"
                enabled: root.resolver && !root.resolver.loading
                  && (!sourceCandidate.intended || !root.resolver.comparison
                    || root.resolver.comparison.ownerToken !== sourceCandidate.modelData.token)
                onClicked: {
                  if (sourceCandidate.intended) root.resolver.compareCards(
                    root.resolver.activeHandle, sourceCandidate.modelData.token)
                  else root.selectCandidate(sourceCandidate.modelData)
                }
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
                ? "These cards are selected only for this session. Manage them without creating a Blip naming preference."
                : root.selectedCandidate
                  ? "If this is a different person, you can remove only this phone number or email after a separate confirmation."
                  : "Select this person to compare and manage their source cards."
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
                    + " · " + sourceCard.modelData.sourceName
                    + (sourceCandidate.modelData.sourceCount > 1
                      ? " · source " + sourceCard.modelData.accountNumber
                        + " of " + sourceCandidate.modelData.sourceCount : "")
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
                  visible: !sourceCandidate.intended && root.selectedCandidate !== null
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
                + root.resolver.repairPreview.cardCount + " from "
                + root.resolver.repairPreview.sourceName + ". This will remove "
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
              ? (root.resolver.undoAction === "edit" ? "Edited one source card for “"
                : root.resolver.undoAction === "delete" ? "Deleted one source card for “"
                : root.resolver.undoAction === "consolidate"
                  ? "Consolidated " + root.resolver.undoCardCount + " source cards for “"
                  : "Removed " + root.resolver.undoHandle + " from “")
                + root.resolver.undoName
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
        text: "Contact editing is disabled. Set contact_writes=on locally and enable the separate owner-only gate on the Mac to use it. Viewing and opening cards remain read-only."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.candidates.length > 0 && root.selectedCandidate !== null
        text: "Viewing or opening a card makes no change. Editing, deletion, consolidation, and handle removal all require a separate confirmation."
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
    visible: !root.reviewActive
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
