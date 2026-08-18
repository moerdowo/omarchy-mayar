import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Mayar merchant balance and recent transactions in the bar.
//
// Every request and the API key itself live in bin/mayarctl — the panel never
// opens a socket, never reads the keyring and never sees the key, so the same
// data is available from a terminal and there is one place where the API
// contract is implemented. This file only renders what `mayarctl status`
// prints, which is always one valid JSON object even when offline or logged
// out.
Panel {
  id: root
  moduleName: "io.github.moerdowo.mayar"
  ipcTarget: "io.github.moerdowo.mayar"

  readonly property string mayarctl: Qt.resolvedUrl("bin/mayarctl").toString().replace("file://", "")

  property bool hasKey: false
  property bool authenticated: false
  property string source: "none"
  property string env: "production"
  property bool keyringAvailable: false
  property var balance: null
  property var paid: []
  property var unpaid: []
  property string lastError: ""
  property bool stale: false
  property bool loading: false

  // Cursor model: the tab chips, then the transaction list.
  readonly property var sections: ["tab", "list"]
  property string focusSection: "tab"
  property int selectedIndex: 0
  property bool cursorActive: false

  property string tab: "paid"

  readonly property var tabOptions: [
    { value: "paid", label: "Paid" },
    { value: "unpaid", label: "Unpaid" }
  ]

  readonly property var rows: tab === "unpaid" ? root.unpaid : root.paid

  // ------------------------------------------------------------ formatting

  // Indonesian grouping is a dot, and rupiah amounts are never fractional in
  // this API, so this is done by hand rather than through a locale that may
  // not be generated on the machine.
  function group(n) {
    var s = String(Math.round(Math.abs(Number(n) || 0)))
    var out = ""
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 === 0) out += "."
      out += s[i]
    }
    return (Number(n) < 0 ? "-" : "") + out
  }

  function idr(n) { return "Rp " + group(n) }

  // The bar has room for a headline, not an exact figure — the panel carries
  // the exact one. Suffixes are the Indonesian ones a Mayar merchant reads
  // without translating: rb / jt / M.
  function idrShort(n) {
    var v = Number(n) || 0
    var sign = v < 0 ? "-" : ""
    v = Math.abs(v)
    function trim(x) {
      var s = x.toFixed(1)
      return s.replace(/\.0$/, "").replace(".", ",")
    }
    if (v >= 1e9) return sign + "Rp " + trim(v / 1e9) + "M"
    if (v >= 1e6) return sign + "Rp " + trim(v / 1e6) + "jt"
    if (v >= 1e4) return sign + "Rp " + trim(v / 1e3) + "rb"
    return sign + idr(v)
  }

  // What a transaction list is actually scanned for is recency — whether the
  // payment at the top landed a minute ago or last Tuesday. A wall-clock stamp
  // makes the reader do that subtraction; "12m ago" is the answer. Only the
  // coarsest unit is shown, because a second figure adds precision nobody is
  // reading a bar panel for.
  //
  // Reads `nowMs` rather than calling Date.now() so every label re-evaluates
  // together when the clock below ticks — a function that sampled the time
  // itself would freeze at whatever the value was when the row was built.
  function fmtRelative(ms) {
    var t = Number(ms)
    if (!isFinite(t) || t <= 0) return ""
    var s = (root.nowMs - t) / 1000
    // A stamp slightly in the future is clock skew between this machine and
    // Mayar's, not a scheduled payment, so it reads as new rather than as a
    // negative age.
    if (s < 45) return "just now"
    // Floor, not round: something 90 minutes old is "1h ago", never "2h ago",
    // which would name a time before it happened. The clamp keeps the first
    // bucket from rendering as "0m ago".
    function ago(v, unit) { return Math.max(1, Math.floor(v)) + unit + " ago" }
    if (s < 3600) return ago(s / 60, "m")
    if (s < 86400) return ago(s / 3600, "h")
    if (s < 7 * 86400) return ago(s / 86400, "d")
    if (s < 30 * 86400) return ago(s / (7 * 86400), "w")
    if (s < 365 * 86400) return ago(s / (30 * 86400), "mo")
    return ago(s / (365 * 86400), "y")
  }

  // ------------------------------------------------------------- state text

  readonly property string statusLine: {
    if (!hasKey) return "NEEDS LOGIN"
    if (!authenticated) return "KEY REJECTED"
    if (balance === null) return lastError !== "" ? "OFFLINE" : "…"
    var s = idrShort(balance.balanceActive)
    if (stale) s += " · STALE"
    else if (env === "sandbox") s += " · SANDBOX"
    return s
  }

  readonly property string barText: {
    if (!hasKey || !authenticated) return "MAYAR"
    if (balance === null) return "MAYAR"
    return idrShort(balance.balanceActive)
  }

  readonly property string sourceLabel: {
    if (source === "env") return "MAYAR_API_KEY"
    if (source === "keyring") return "keyring"
    if (source === "file") return "config file"
    return "none"
  }

  // ------------------------------------------------------------ navigation

  function sectionCount(section) {
    if (section === "tab") return tabOptions.length
    if (section === "list") return rows.length
    return 0
  }

  function moveCursor(delta) {
    var idx = sections.indexOf(focusSection)
    if (idx < 0) idx = 0
    var next = idx + delta
    if (next < 0) next = 0
    if (next > sections.length - 1) next = sections.length - 1
    // Skip a section with nothing in it rather than parking the cursor on an
    // empty list, which looks like the panel stopped responding.
    if (sectionCount(sections[next]) === 0) return
    focusSection = sections[next]
    selectedIndex = 0
  }

  function moveCursorH(delta) {
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > sectionCount(focusSection) - 1) next = sectionCount(focusSection) - 1
    selectedIndex = next
  }

  function activateCursor() {
    if (focusSection === "tab") {
      if (selectedIndex >= 0 && selectedIndex < tabOptions.length)
        setTab(tabOptions[selectedIndex].value)
    } else if (focusSection === "list") {
      if (selectedIndex >= 0 && selectedIndex < rows.length)
        copyRow(rows[selectedIndex])
    }
  }

  // -------------------------------------------------------------- actions

  function setTab(v) {
    root.tab = v
    root.selectedIndex = 0
  }

  function refresh(force) {
    if (statusProc.running) return
    root.loading = true
    statusProc.command = force
      ? [root.mayarctl, "status", "-n", "8", "-f"]
      : [root.mayarctl, "status", "-n", "8"]
    statusProc.running = true
  }

  // Unpaid rows carry a payment URL worth sending to a customer; paid rows
  // only have an id worth quoting in support. Copy whichever exists.
  function copyRow(row) {
    if (!row) return
    var text = row.url ? String(row.url) : String(row.id || "")
    if (text === "") return
    copyProc.command = ["wl-copy", "--", text]
    if (!copyProc.running) copyProc.running = true
    root.copied = text
    copiedTimer.restart()
  }

  property string copied: ""

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copied = ""
  }

  // Relative ages go stale on their own, with no new data involved, so the
  // panel keeps its own clock instead of only re-reading `createdAt` when a
  // refresh lands. It ticks only while the list is on screen; a closed panel
  // has nothing whose age is visible. `triggeredOnStart` resets it on open,
  // so the first frame is never showing an age from the last time it was up.
  property double nowMs: Date.now()

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh(false)

  onOpenedChanged: {
    if (opened) {
      refresh(true)
      focusSection = "tab"
      selectedIndex = 0
      cursorActive = false
    }
  }

  // mayarctl caches responses for MAYAR_CACHE_TTL (60s default), so a poll
  // that lands inside the window costs nothing over the network. The closed
  // cadence is still slow: it only feeds the bar headline.
  Timer {
    interval: root.opened ? 20000 : 300000
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var parsed
        try {
          parsed = JSON.parse(String(text || "{}"))
        } catch (e) {
          // status is contracted to always print valid JSON; if it did not,
          // keep the previous numbers rather than blanking the panel.
          return
        }
        root.hasKey = !!parsed.hasKey
        root.authenticated = !!parsed.authenticated
        root.source = String(parsed.source || "none")
        root.env = String(parsed.env || "production")
        root.keyringAvailable = !!parsed.keyringAvailable
        root.balance = parsed.balance || null
        root.paid = parsed.paid || []
        root.unpaid = parsed.unpaid || []
        root.stale = !!parsed.stale
        root.lastError = parsed.error ? String(parsed.error) : ""
      }
    }
    onRunningChanged: if (!running) root.loading = false
  }

  Process {
    id: copyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The brand mark instead of a glyph, via the same iconComponent hook the
    // first-party Dropbox and Tailscale widgets use.
    iconComponent: Component {
      Item {
        MayarIcon {
          anchors.centerIn: parent
          // The stock glyphs are text, and their ink sits a little above the
          // centre of the box they are laid out in; a shape centred honestly
          // ends up sitting a pixel low next to them. Measured off the bar as
          // 1.5 physical pixels at 1.6x scale.
          anchors.verticalCenterOffset: -1
          iconSize: Style.space(13)
          color: root.bar.foreground
          // No key, a rejected key, or numbers that could not be refreshed.
          attention: !root.authenticated || root.stale || root.lastError !== ""
        }
      }
    }
    tooltipText: {
      if (!root.hasKey) return "Mayar · not logged in"
      if (!root.authenticated) return "Mayar · API key rejected"
      if (root.balance === null) return "Mayar · " + (root.lastError !== "" ? root.lastError : "loading")
      var t = "Mayar · " + root.idr(root.balance.balanceActive) + " available"
      if (Number(root.balance.balancePending) > 0)
        t += " · " + root.idr(root.balance.balancePending) + " pending"
      if (root.stale) t += " · stale"
      return t
    }
    onPressed: function (b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          MayarIcon {
            id: heroIcon
            // Sized to stand as tall as the MAYAR + status block beside it,
            // rather than to the display font it used to borrow. At that size
            // the mark was shorter than its own caption, which reads as an
            // icon that wandered in from the bar; a hero is the one place the
            // brand gets to be the brand. Still expressed against a font token
            // so it tracks a theme that scales type, and MayarIcon's cap ratio
            // still applies, which is why the multiplier looks large.
            iconSize: Style.font.display * 1.5
            color: root.bar.foreground
            attention: !root.authenticated
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "MAYAR"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusLine
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Login notice ----------
        PanelSeparator {
          visible: !root.hasKey || !root.authenticated
          foreground: root.bar.foreground
        }

        Text {
          visible: !root.hasKey || !root.authenticated
          width: parent.width
          wrapMode: Text.WordWrap
          text: {
            var cmd = "~/.config/omarchy/plugins/io.github.moerdowo.mayar/bin/mayarctl login"
            if (!root.hasKey)
              return "No API key yet. In a terminal, run:\n\n" + cmd +
                     "\n\nIt asks for a key once and stores it in your login keyring. " +
                     "Or export MAYAR_API_KEY instead if you'd rather not use the keyring."
            return "Mayar rejected the key from " + root.sourceLabel +
                   ". Create a new one at web.mayar.id → Integrasi › Api Keys, then run:\n\n" + cmd
          }
          color: Qt.darker(root.bar.foreground, 1.2)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---------- Balance ----------
        PanelSeparator {
          visible: root.balance !== null
          foreground: root.bar.foreground
        }

        Column {
          visible: root.balance !== null
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "BALANCE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          BalanceRow {
            width: parent.width
            label: "Available"
            // The one number that answers "can I withdraw right now", so it is
            // the only one given full weight.
            value: root.balance ? root.idr(root.balance.balanceActive) : "—"
            emphasised: true
          }

          BalanceRow {
            width: parent.width
            label: "Pending"
            value: root.balance ? root.idr(root.balance.balancePending) : "—"
          }

          BalanceRow {
            width: parent.width
            label: "Total"
            value: root.balance ? root.idr(root.balance.balance) : "—"
          }
        }

        // ---------- Transactions ----------
        PanelSeparator {
          visible: root.authenticated
          foreground: root.bar.foreground
        }

        Column {
          visible: root.authenticated
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "TRANSACTIONS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ButtonGroup {
            id: tabGroup
            options: root.tabOptions
            value: root.tab
            foreground: root.bar.foreground
            background: root.bar.background
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.caption
            focusable: false
            cursorIndex: root.cursorActive && root.focusSection === "tab" ? root.selectedIndex : -1
            onChanged: function (v) {
              root.focusSection = "tab"
              root.setTab(v)
            }
            onHovered: function (index, isHovered) {
              if (!isHovered) return
              root.cursorActive = true
              root.focusSection = "tab"
              root.selectedIndex = index
            }
          }

          Text {
            visible: root.rows.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError !== ""
              ? root.lastError
              : (root.loading ? "Loading…"
                              : (root.tab === "unpaid" ? "No unpaid transactions."
                                                       : "No paid transactions yet."))
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          // A bounded ListView rather than a Repeater in the Column. The panel
          // window is sized from panelColumn.implicitHeight and then capped,
          // but nothing clips it — so a Repeater with a busy month in it draws
          // its last rows outside the panel border and pushes the footer off.
          // ListView also gives positionViewAtIndex for free, which is what
          // keeps the keyboard-selected row on screen as j/k walk past the
          // bottom of the visible window.
          ListView {
            id: txList
            width: parent.width
            // Bounded so hero + balance + list + footer stay under the panel's
            // own cap below. Nothing clips panelColumn itself, so if the sum
            // exceeds that cap the footer draws outside the panel border —
            // this is the term that has to give.
            height: Math.min(contentHeight, Style.space(200))
            spacing: 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.rows
            currentIndex: root.focusSection === "list" ? root.selectedIndex : -1
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            // Switching tabs swaps the model under the view, which resets its
            // scroll position after this binding has already run — so put the
            // list back at the top a turn later rather than mid-swap.
            onModelChanged: Qt.callLater(function () { txList.positionViewAtBeginning() })

            delegate: Item {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: txDelegate.implicitHeight

              TxRow {
                id: txDelegate
                width: parent.width
                tx: parent.modelData
                rowIndex: parent.index
              }
            }
          }
        }

        // ---------- Footer ----------
        PanelSeparator {
          visible: root.hasKey
          foreground: root.bar.foreground
        }

        Item {
          visible: root.hasKey
          width: parent.width
          implicitHeight: footLeft.implicitHeight + Style.space(4)

          Text {
            id: footLeft
            text: root.copied !== "" ? "COPIED" : ("KEY · " + root.sourceLabel.toUpperCase())
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.left: parent.left
            anchors.bottom: parent.bottom
          }

          Text {
            // Sandbox and production are different accounts with different
            // money in them; never let the panel be ambiguous about which.
            text: root.env === "sandbox" ? "SANDBOX" : "PRODUCTION"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.bottom: parent.bottom
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component BalanceRow: Item {
    id: balRow
    property string label: ""
    property string value: ""
    property bool emphasised: false

    implicitHeight: balLabel.implicitHeight + Style.space(8)

    Text {
      id: balLabel
      text: balRow.label
      color: Qt.darker(root.bar.foreground, balRow.emphasised ? 1.0 : 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: balRow.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: balRow.emphasised ? Style.font.title : Style.font.body
      font.bold: balRow.emphasised
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component TxRow: Item {
    id: txRow
    property var tx: null
    property int rowIndex: -1

    readonly property bool selected: root.cursorActive &&
                                     root.focusSection === "list" &&
                                     root.selectedIndex === txRow.rowIndex

    implicitHeight: txTop.implicitHeight + txBottom.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(4)
      anchors.rightMargin: -Style.space(4)
      color: Style.hoverFill
      visible: txRow.selected
      radius: Style.cornerRadius
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: {
        root.cursorActive = true
        root.focusSection = "list"
        root.selectedIndex = txRow.rowIndex
      }
      onClicked: root.copyRow(txRow.tx)
    }

    Text {
      id: txTop
      // Whoever paid is the thing being scanned for; the product name is the
      // fallback when a transaction has no customer attached.
      text: txRow.tx ? String(txRow.tx.customer || txRow.tx.label || "—") : ""
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: Style.space(3)
      width: parent.width * 0.56
    }

    Text {
      text: txRow.tx ? root.idr(txRow.tx.amount) : ""
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.top: txTop.top
    }

    Text {
      id: txBottom
      text: {
        if (!txRow.tx) return ""
        var bits = []
        var d = root.fmtRelative(txRow.tx.createdAt)
        if (d !== "") bits.push(d)
        if (txRow.tx.method) bits.push(String(txRow.tx.method))
        else if (txRow.tx.type) bits.push(String(txRow.tx.type).replace(/_/g, " "))
        return bits.join(" · ")
      }
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.top: txTop.bottom
      width: parent.width * 0.56
    }

    Text {
      // Paid rows say settled/pending; unpaid rows say active/expired. Both
      // matter, and neither is inferable from the amount.
      text: txRow.tx ? String(txRow.tx.status || "").toUpperCase() : ""
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.0
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.top: txBottom.top
    }
  }
}
