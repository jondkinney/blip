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

  spacing: space(9)

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
  function unionRows(value) {
    if (!value || !Array.isArray(value.cards)) return []
    var result = []
    var seen = ({})
    for (var cardIndex = 0; cardIndex < value.cards.length; cardIndex++) {
      var rows = cardRows(value.cards[cardIndex])
      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
        var row = rows[rowIndex]
        var key = row.label.toLowerCase() + "\u0000" + row.value.toLowerCase()
        if (seen[key]) continue
        seen[key] = true
        result.push(row)
      }
    }
    return result
  }
  function missingDetails(card) {
    if (!card) return ""
    var missing = []
    if (String(card.firstName || "") === "" && String(card.lastName || "") === "") missing.push("name")
    if (!card.phones || card.phones.length === 0) missing.push("phone")
    if (!card.emails || card.emails.length === 0) missing.push("email")
    if (!card.addresses || card.addresses.length === 0) missing.push("address")
    if (String(card.birthday || "") === "") missing.push("birthday")
    return missing.length === 0 ? "Core details present" : "Missing: " + missing.join(", ")
  }

  Text {
    Layout.fillWidth: true
    text: "COMPARE ACTIVE CARDS"
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.2)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize(Style.font.caption)
    font.bold: true
  }

  Text {
    Layout.fillWidth: true
    text: root.comparison
      ? "These are the " + root.comparison.cardCount + " active cards Contacts currently uses for “"
        + root.comparison.name + ".” Compare them here before opening, completing, or linking them. Nothing has changed."
      : ""
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
      label: "Refresh details"
      enabled: root.resolver && !root.resolver.loading && root.comparison
      onClicked: root.resolver.compareCards(root.comparison.handle, root.comparison.ownerToken)
    }
    SmallButton {
      label: "Close comparison"
      enabled: root.resolver && !root.resolver.loading
      onClicked: root.resolver.cancelComparison()
    }
    Item { Layout.fillWidth: true }
    SmallButton {
      visible: !root.resolver || root.resolver.linkPreview === null
      primary: true
      label: "Prepare link in Contacts…"
      enabled: root.resolver && !root.resolver.loading && root.comparison
        && root.resolver.contactWrites && root.comparison.writeEnabled
      onClicked: root.resolver.prepareLink()
    }
  }

  Rectangle {
    Layout.fillWidth: true
    visible: root.resolver && root.resolver.linkPreview !== null
    implicitHeight: topLinkContents.implicitHeight + root.space(18)
    radius: root.corner(root.space(9))
    color: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
      ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.09)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
    border.width: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready ? 2 : 1
    border.color: root.resolver && root.resolver.linkPreview && root.resolver.linkPreview.ready
      ? root.urgent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)

    ColumnLayout {
      id: topLinkContents
      anchors.fill: parent
      anchors.margins: root.space(9)
      spacing: root.space(7)
      Text {
        Layout.fillWidth: true
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
        text: root.resolver && root.resolver.linkPreview
          ? root.resolver.linkPreview.ready
            ? "Run Contacts’ “" + root.resolver.linkPreview.action + "” on these exact "
              + root.resolver.linkPreview.cardCount + " cards? This changes Contacts and may sync to their source accounts. Blip cannot provide an automatic unlink receipt."
            : "Contacts disabled “" + root.resolver.linkPreview.action
              + "” for this exact selection. The cards may already be linked, or Contacts may not consider them linkable. Nothing has changed."
          : ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }
      RowLayout {
        Layout.fillWidth: true
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

  GridLayout {
    Layout.fillWidth: true
    columns: root.width >= root.space(820) && root.comparison && root.comparison.cardCount === 2 ? 2 : 1
    columnSpacing: root.space(8)
    rowSpacing: root.space(8)

    Repeater {
      model: root.comparison ? root.comparison.cards : []
      delegate: Rectangle {
        id: cardBox
        required property var modelData
        Layout.fillWidth: true
        Layout.preferredWidth: root.space(390)
        Layout.alignment: Qt.AlignTop
        implicitHeight: cardContents.implicitHeight + root.space(18)
        radius: root.corner(root.space(9))
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)

        ColumnLayout {
          id: cardContents
          anchors.fill: parent
          anchors.margins: root.space(9)
          spacing: root.space(6)

          RowLayout {
            Layout.fillWidth: true
            spacing: root.space(8)
            ColumnLayout {
              Layout.fillWidth: true
              spacing: root.space(1)
              Text {
                Layout.fillWidth: true
                text: "CARD " + cardBox.modelData.cardNumber + " · CONTACT ACCOUNT "
                  + cardBox.modelData.accountNumber
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
                font.bold: true
              }
              Text {
                Layout.fillWidth: true
                text: root.missingDetails(cardBox.modelData)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.missingDetails(cardBox.modelData).indexOf("Missing:") === 0
                  ? root.urgent : root.accent
                font.family: root.fontFamily
                font.pixelSize: root.fontSize(Style.font.caption)
              }
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
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
          }

          Repeater {
            model: root.cardRows(cardBox.modelData)
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: root.space(7)
              Text {
                Layout.preferredWidth: root.space(98)
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

  Rectangle {
    Layout.fillWidth: true
    visible: root.comparison !== null
    implicitHeight: combinedContents.implicitHeight + root.space(18)
    radius: root.corner(root.space(9))
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08)
    border.width: 1
    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)

    ColumnLayout {
      id: combinedContents
      anchors.fill: parent
      anchors.margins: root.space(9)
      spacing: root.space(5)
      RowLayout {
        Layout.fillWidth: true
        spacing: root.space(8)
        Text {
          Layout.fillWidth: true
          text: "COMBINED VIEW"
          textFormat: Text.PlainText
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.fontSize(Style.font.caption)
          font.bold: true
        }
        SmallButton {
          label: root.combinedExpanded ? "Hide combined values" : "Show combined values"
          onClicked: root.combinedExpanded = !root.combinedExpanded
        }
      }
      Text {
        Layout.fillWidth: true
        text: "Unique values across the active cards. Linking normally presents one combined person while each synced account keeps its source card; a same-account merge can consolidate source cards."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize(Style.font.caption)
      }
      Repeater {
        model: root.combinedExpanded ? root.unionRows(root.comparison) : []
        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          spacing: root.space(7)
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
