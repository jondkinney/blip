import QtQuick
import QtQuick.Layouts
import qs.Commons

// A read-only local comparison of the exact active Contacts cards selected by
// the bridge. Linking remains a separate, explicit action in Contacts.app.
ColumnLayout {
  id: root

  property var resolver: null
  property var comparison: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontScale: 1.0
  property real density: 1.0
  property real cornerScale: 1.0
  property bool combinedExpanded: false
  property bool showSharedFields: false
  readonly property int sharedCount: sharedRowCount(comparison)

  onComparisonChanged: {
    showSharedFields = false
    combinedExpanded = false
  }

  spacing: space(18)

  function fontSize(value) { return Math.max(1, Math.round(value * fontScale)) }
  function space(value) { return Math.max(1, Math.round(Style.spaceReal(value) * density)) }
  function corner(value) { return Math.max(0, Math.round(value * cornerScale)) }
  function cleanLabel(value) {
    var label = String(value || "")
    var apple = /^_\$!<(.+)>!\$_$/.exec(label)
    return apple ? apple[1] : label
  }
  function appendRow(rows, label, value) {
    var text = String(value || "").trim()
    if (text !== "") rows.push({ label: label, value: text })
  }
  function addressText(address) {
    var parts = []
    var street = String(address && address.street || "").trim()
    var city = String(address && address.city || "").trim()
    var state = String(address && address.state || "").trim()
    var postal = String(address && address.postalCode || "").trim()
    var country = String(address && address.country || "").trim()
    if (street !== "") parts.push(street)
    var locality = [city, state, postal].filter(function(value) { return value !== "" }).join(" ")
    if (locality !== "") parts.push(locality)
    if (country !== "") parts.push(country)
    return parts.join(", ")
  }
  function cardRows(card) {
    if (!card) return []
    var rows = []
    appendRow(rows, "Display name", card.displayName)
    appendRow(rows, "First name", card.firstName)
    appendRow(rows, "Middle name", card.middleName)
    appendRow(rows, "Last name", card.lastName)
    appendRow(rows, "Nickname", card.nickname)
    appendRow(rows, "Organization", card.organization)
    appendRow(rows, "Department", card.department)
    appendRow(rows, "Job title", card.jobTitle)
    appendRow(rows, "Birthday", card.birthday)
    var groups = [
      { name: "Phone", values: card.phones || [] },
      { name: "Email", values: card.emails || [] },
      { name: "Website", values: card.urls || [] }
    ]
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      var group = groups[groupIndex]
      for (var valueIndex = 0; valueIndex < group.values.length; valueIndex++) {
        var item = group.values[valueIndex]
        var itemLabel = cleanLabel(item.label)
        appendRow(rows, group.name + (itemLabel === "" ? "" : " · " + itemLabel), item.value)
      }
    }
    var addresses = card.addresses || []
    for (var addressIndex = 0; addressIndex < addresses.length; addressIndex++) {
      var address = addresses[addressIndex]
      var addressLabel = cleanLabel(address.label)
      appendRow(rows, "Address" + (addressLabel === "" ? "" : " · " + addressLabel), addressText(address))
    }
    appendRow(rows, "Notes", card.note)
    return rows
  }
  function rowKey(row) {
    return String(row && row.label || "").toLowerCase() + "\u0000"
      + String(row && row.value || "").toLowerCase()
  }
  function sharedRowMap(value) {
    var result = ({})
    if (!value || !Array.isArray(value.cards) || value.cards.length < 2) return result
    var counts = ({})
    for (var cardIndex = 0; cardIndex < value.cards.length; cardIndex++) {
      var perCard = ({})
      var rows = cardRows(value.cards[cardIndex])
      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) perCard[rowKey(rows[rowIndex])] = true
      var keys = Object.keys(perCard)
      for (var keyIndex = 0; keyIndex < keys.length; keyIndex++)
        counts[keys[keyIndex]] = Number(counts[keys[keyIndex]] || 0) + 1
    }
    var allKeys = Object.keys(counts)
    for (var index = 0; index < allKeys.length; index++) {
      var key = allKeys[index]
      if (counts[key] === value.cards.length) result[key] = true
    }
    return result
  }
  function sharedRowCount(value) { return Object.keys(sharedRowMap(value)).length }
  function visibleRows(card) {
    var rows = cardRows(card)
    if (showSharedFields) return rows
    var shared = sharedRowMap(comparison)
    return rows.filter(function(row) { return !shared[rowKey(row)] })
  }
  function unionRows(value) {
    if (!value || !Array.isArray(value.cards)) return []
    var result = []
    var seen = ({})
    for (var cardIndex = 0; cardIndex < value.cards.length; cardIndex++) {
      var rows = cardRows(value.cards[cardIndex])
      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
        var row = rows[rowIndex]
        var key = rowKey(row)
        if (seen[key]) continue
        seen[key] = true
        result.push(row)
      }
    }
    return result
  }
  function missingFields(card) {
    if (!card) return []
    var missing = []
    if (String(card.firstName || "") === "" && String(card.lastName || "") === "") missing.push("name")
    if (!card.phones || card.phones.length === 0) missing.push("phone")
    if (!card.emails || card.emails.length === 0) missing.push("email")
    if (!card.addresses || card.addresses.length === 0) missing.push("address")
    if (String(card.birthday || "") === "") missing.push("birthday")
    return missing
  }
  function missingDetails(card) {
    var missing = missingFields(card)
    return missing.length === 0 ? "Core details present" : "Missing: " + missing.join(", ")
  }
  function incompleteCardCount(value) {
    if (!value || !Array.isArray(value.cards)) return 0
    var count = 0
    for (var i = 0; i < value.cards.length; i++) if (missingFields(value.cards[i]).length > 0) count++
    return count
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: root.space(10)
    ColumnLayout {
      Layout.fillWidth: true
      spacing: root.space(2)
      Text {
        Layout.fillWidth: true
        text: root.comparison ? root.comparison.name : "Contact cards"
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.body)
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        text: root.comparison
          ? root.comparison.cardCount + " source cards · " + root.comparison.sourceCount
            + (root.comparison.sourceCount === 1 ? " account" : " accounts")
          : ""
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }
    }
    SmallButton {
      label: "Refresh"
      enabled: root.resolver && !root.resolver.loading && root.comparison
      onClicked: root.resolver.compareCards(root.comparison.handle, root.comparison.ownerToken)
    }
    SmallButton {
      label: "Close"
      enabled: root.resolver && !root.resolver.loading
      onClicked: root.resolver.cancelComparison()
    }
  }

  StageHeader {
    step: "1"
    title: "Compare"
    detail: root.showSharedFields || root.sharedCount === 0
      ? "Showing every discovered value."
      : root.sharedCount + (root.sharedCount === 1 ? " shared value is" : " shared values are")
        + " tucked away so differences stand out."
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: root.space(8)
    Text {
      Layout.fillWidth: true
      text: root.showSharedFields ? "ALL FIELDS" : "DIFFERENCES ONLY"
      textFormat: Text.PlainText
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: root.fontSize(Style.font.caption)
      font.bold: true
    }
    SmallButton {
      visible: root.sharedCount > 0
      label: root.showSharedFields ? "Show differences only" : "Show all fields"
      onClicked: root.showSharedFields = !root.showSharedFields
    }
  }

  GridLayout {
    Layout.fillWidth: true
    columns: root.width >= root.space(820) && root.comparison && root.comparison.cardCount === 2 ? 2 : 1
    columnSpacing: root.space(12)
    rowSpacing: root.space(12)

    Repeater {
      model: root.comparison ? root.comparison.cards : []
      delegate: Rectangle {
        id: cardBox
        required property var modelData
        readonly property var displayedRows: root.visibleRows(modelData)
        Layout.fillWidth: true
        Layout.preferredWidth: root.space(390)
        Layout.alignment: Qt.AlignTop
        implicitHeight: cardContents.implicitHeight + root.space(28)
        radius: root.corner(root.space(12))
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

        ColumnLayout {
          id: cardContents
          anchors.fill: parent
          anchors.margins: root.space(14)
          spacing: root.space(10)

          RowLayout {
            Layout.fillWidth: true
            spacing: root.space(8)
            Text {
              Layout.fillWidth: true
              text: "SOURCE CARD " + cardBox.modelData.cardNumber
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.caption)
              font.bold: true
            }
            InfoPill { label: "ACCOUNT " + cardBox.modelData.accountNumber }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: root.space(8)
            Text {
              Layout.fillWidth: true
              text: root.missingDetails(cardBox.modelData)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.missingFields(cardBox.modelData).length > 0 ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontSize(Style.font.caption)
            }
            SmallButton {
              label: "Open & edit on Mac…"
              enabled: root.resolver && !root.resolver.loading
              onClicked: root.resolver.openOnMac(root.comparison.handle, cardBox.modelData.token)
            }
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.13)
          }

          Text {
            Layout.fillWidth: true
            visible: cardBox.displayedRows.length === 0
            text: "No card-specific values."
            textFormat: Text.PlainText
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }

          Repeater {
            model: cardBox.displayedRows
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: root.space(10)
              Text {
                Layout.preferredWidth: root.space(106)
                Layout.alignment: Qt.AlignTop
                text: String(modelData.label || "")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(root.foreground, 1.45)
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
              }
              Text {
                Layout.fillWidth: true
                text: String(modelData.value || "")
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
              }
            }
          }
        }
      }
    }
  }

  StageHeader {
    step: "2"
    title: "Complete"
    detail: root.incompleteCardCount(root.comparison) === 0
      ? "Both source cards have their core details."
      : "Open a source card above to fill its missing details in Contacts, then refresh here."
  }

  Rectangle {
    Layout.fillWidth: true
    visible: root.comparison !== null
    implicitHeight: combinedContents.implicitHeight + root.space(24)
    radius: root.corner(root.space(10))
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.065)
    border.width: 1
    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.28)

    ColumnLayout {
      id: combinedContents
      anchors.fill: parent
      anchors.margins: root.space(12)
      spacing: root.space(8)
      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        ColumnLayout {
          Layout.fillWidth: true
          spacing: root.space(2)
          Text {
            Layout.fillWidth: true
            text: "MERGED PREVIEW"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: "Unique values Blip discovered across every active source card."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
        }
        SmallButton {
          label: root.combinedExpanded ? "Hide preview" : "Show merged values"
          onClicked: root.combinedExpanded = !root.combinedExpanded
        }
      }
      Repeater {
        model: root.combinedExpanded ? root.unionRows(root.comparison) : []
        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          spacing: root.space(10)
          Text {
            Layout.preferredWidth: root.space(112)
            Layout.alignment: Qt.AlignTop
            text: String(modelData.label || "")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.foreground, 1.45)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
          Text {
            Layout.fillWidth: true
            text: String(modelData.value || "")
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontSize(Style.font.caption)
          }
        }
      }
    }
  }

  StageHeader {
    step: "3"
    title: "Link"
    detail: "Ask Contacts whether it can link these exact source cards. Checking makes no changes."
  }

  Rectangle {
    Layout.fillWidth: true
    implicitHeight: linkContents.implicitHeight + root.space(24)
    radius: root.corner(root.space(10))
    color: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
      ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.09)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
    border.width: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready ? 2 : 1
    border.color: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
      ? root.urgent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

    ColumnLayout {
      id: linkContents
      anchors.fill: parent
      anchors.margins: root.space(12)
      spacing: root.space(9)

      RowLayout {
        Layout.fillWidth: true
        visible: !root.resolver || root.resolver.linkPreview === null
        spacing: root.space(10)
        Text {
          Layout.fillWidth: true
          text: "Contacts keeps the source accounts authoritative. Blip only selects the exact cards and requests Apple’s action."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: root.fontSize(Style.font.caption)
        }
        SmallButton {
          primary: true
          label: "Prepare link in Contacts…"
          enabled: root.resolver && !root.resolver.loading && root.comparison
            && root.resolver.contactWrites && root.comparison.writeEnabled
          onClicked: root.resolver.prepareLink()
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.linkPreview !== null
        text: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
          ? "CONFIRM AN UPSTREAM CONTACTS CHANGE"
          : "CONTACTS DID NOT OFFER THIS ACTION"
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
          ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.linkPreview !== null
        text: root.resolver && root.resolver.linkPreview
          ? root.resolver.linkPreview.ready
            ? "Run Contacts’ “" + root.resolver.linkPreview.action + "” on these exact "
              + root.resolver.linkPreview.cardCount + " cards? This changes Contacts and may sync to their source accounts. Blip cannot provide an automatic unlink receipt."
            : "Contacts disabled “" + root.resolver.linkPreview.action
              + "” for this selection. The cards may already be linked or ineligible. Nothing changed."
          : ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }
      RowLayout {
        Layout.fillWidth: true
        visible: root.resolver && root.resolver.linkPreview !== null
        spacing: root.space(8)
        Item { Layout.fillWidth: true }
        SmallButton {
          label: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
            ? "Cancel" : "Dismiss"
          enabled: root.resolver && !root.resolver.loading
          onClicked: root.resolver.cancelLink()
        }
        SmallButton {
          visible: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
          danger: true
          primary: true
          label: root.resolver && root.resolver.linkPreview
            ? "Run “" + root.resolver.linkPreview.action + "”"
            : "Run Contacts action"
          enabled: root.resolver && !root.resolver.loading && root.resolver.linkPreview
            && root.resolver.linkPreview.ready && root.resolver.linkPreview.writeEnabled
          onClicked: root.resolver.linkCards()
        }
      }
    }
  }

  Text {
    Layout.fillWidth: true
    visible: root.resolver && !root.resolver.contactWrites
    text: "Linking is disabled by the local and Mac write gates. Comparing and opening exact cards remain read-only."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.foreground, 1.35)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
  }

  component StageHeader: RowLayout {
    property string step: ""
    property string title: ""
    property string detail: ""
    Layout.fillWidth: true
    spacing: root.space(10)
    Rectangle {
      Layout.preferredWidth: root.space(26)
      Layout.preferredHeight: root.space(26)
      radius: width / 2
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
      border.width: 1
      border.color: root.accent
      Text {
        anchors.centerIn: parent
        text: parent.parent.step
        textFormat: Text.PlainText
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: root.space(1)
      Text {
        Layout.fillWidth: true
        text: parent.parent.title.toUpperCase()
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        text: parent.parent.detail
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }
    }
  }

  component InfoPill: Rectangle {
    property string label: ""
    implicitWidth: pillText.implicitWidth + root.space(12)
    implicitHeight: pillText.implicitHeight + root.space(6)
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
    Text {
      id: pillText
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.25)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize(Style.font.caption)
    }
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
