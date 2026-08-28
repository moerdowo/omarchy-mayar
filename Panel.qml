import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Mayar merchant balance and recent transactions in the bar.
//
// Every request lives in bin/mayarctl — the panel never opens a socket and
// never reads the keyring, so the same data is available from a terminal and
// there is one place where the API contract is implemented. This file renders
// what `mayarctl status` prints, which is always one valid JSON object even
// when offline or unauthenticated.
//
// The one credential this file touches is a key being typed into it, and it
// only carries it as far as `mayarctl set-key`'s stdin (see setKeyProc). It is
// never stored here, never put in a process argument, and dropped from the
// field as soon as the helper says it works.
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

  // Key entry. `keyMessage` is the one line under the field; `keyOk` only
  // decides whether it is drawn as prose or as an error, so a success note and
  // a rejection can share the slot.
  property bool savingKey: false
  property string keyMessage: ""
  property bool keyOk: false

  readonly property bool needsKey: !hasKey || !authenticated

  readonly property color urgent: bar ? bar.urgent : Color.urgent

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

  // ----------------------------------------------------------- sanitising

  // Everything mayarctl returns except the balance figures is API-controlled,
  // and some of it is controlled by strangers: a customer types their own name
  // at checkout, and an error string is whatever Mayar's server chose to send.
  //
  // QML Text defaults to Text.AutoText, which runs Qt.mightBeRichText() over
  // the string and hands anything that looks like markup to the StyledText
  // parser — and StyledText honours <img src="https://…"> by fetching it. A
  // customer named `<img src=https://tracker.example/x.png>` would then have
  // every panel that renders that row phone home on its own: the merchant's IP
  // address, the fact that they run this widget, and the moment they opened it.
  // Nothing needs to be clicked.
  //
  // Every Text below sets textFormat: Text.PlainText, which is the real fix.
  // Strings are also stripped here, because two paths leave this file: the bar
  // tooltip is laid out by the shell's PanelToolTip, whose Text this plugin
  // does not own, and anything a future shared component renders would inherit
  // the same default. Angle brackets go because no tag can begin without one;
  // control characters go because one row is one line; the length is clamped
  // because a name is not a payload.
  function sanitise(v) {
    if (v === null || v === undefined) return ""
    return String(v)
      .replace(/[<>]/g, "")
      .replace(/[\x00-\x1f\x7f-\x9f]/g, " ")
      .slice(0, 160)
      .trim()
  }

  // For the two fields that are copied rather than drawn — a payment URL and a
  // transaction id. Clamping these to 160 characters the way a label is clamped
  // would hand someone a silently truncated URL, which is worse than a long
  // one, so only the characters that could confuse a clipboard or a terminal
  // come out.
  function sanitiseOpaque(v) {
    if (v === null || v === undefined) return ""
    return String(v).replace(/[\x00-\x1f\x7f-\x9f]/g, "").slice(0, 2048)
  }

  // Rows are rebuilt field by field rather than patched, so a field added to
  // mayarctl later cannot reach a Text without being named here first.
  function sanitiseRows(rows) {
    if (!Array.isArray(rows)) return []
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i] || {}
      out.push({
        id: sanitiseOpaque(r.id),
        kind: sanitise(r.kind),
        amount: Number(r.amount) || 0,
        status: sanitise(r.status),
        createdAt: Number(r.createdAt) || 0,
        method: sanitise(r.method),
        type: sanitise(r.type),
        customer: sanitise(r.customer),
        label: sanitise(r.label),
        url: sanitiseOpaque(r.url),
        fee: Number(r.fee) || 0
      })
    }
    return out
  }

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
    if (!hasKey) return "NEEDS KEY"
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

  // ------------------------------------------------------- running helpers

  // Two things quickshell's Process does not do, and both of them are
  // unbounded.
  //
  // StdioCollector has no ceiling: it appends every byte the child writes until
  // the stream ends. The row limits further down this file only apply to JSON
  // that has already been parsed, which is far too late to be what bounds
  // memory — by then the bytes have been through a shell variable, jq, the
  // cache and QString. `head -c` in front of the pipe is early enough: it
  // closes the read end at the ceiling and the helper dies of SIGPIPE.
  //
  // `running` has no deadline: a helper wedged on a read that never returns
  // never emits streamFinished, so `waitForEnd` waits forever and the panel
  // sits on "Verifying…" with nothing that will ever take it off. `timeout -s
  // KILL` is a deadline the kernel enforces on the helper itself; the kill
  // timers below are the one this file enforces on its own state, so the UI
  // recovers even in the case where the child cannot be reaped at all.
  //
  // sh is handed one fixed script and nothing else. The ceiling, the deadline
  // and the command line all arrive as positional arguments, so no value from
  // a row, an error string or a key is ever parsed as shell.
  readonly property int helperTimeout: 20         // seconds, enforced by timeout(1)
  readonly property int maxHelperBytes: 1048576   // 1 MiB, enforced by head(1)

  function guarded(argv) {
    return ["/bin/sh", "-c",
            'cap=$1; secs=$2; shift 2; timeout -s KILL "$secs" "$@" 2>/dev/null | head -c "$cap"',
            "mayar-guard", String(root.maxHelperBytes), String(root.helperTimeout)]
           .concat(argv)
  }

  // Runs a kill timer for exactly as long as its process does, so a deadline is
  // never left armed against a process that already finished.
  function armDeadline(timer, proc) {
    if (proc.running) timer.restart()
    else timer.stop()
  }

  // Long enough that the guard's own `timeout` always gets to act first — this
  // is the backstop for the guard failing, not a second racing deadline.
  readonly property int deadlineMs: (helperTimeout + 5) * 1000

  // -------------------------------------------------------------- actions

  function setTab(v) {
    root.tab = v
    root.selectedIndex = 0
  }

  // Hands the key to mayarctl and forgets it here. The field keeps its text
  // until the helper says the key works, so a rejected key can be corrected
  // rather than re-pasted; on success both copies are dropped and the only one
  // left anywhere is the one in the keyring.
  function submitKey(k) {
    var key = String(k || "").replace(/\s/g, "")
    if (key === "" || root.savingKey) return
    root.savingKey = true
    root.keyOk = false
    root.keyMessage = "Verifying…"
    setKeyProc.gotResult = false
    setKeyProc.secret = key
    setKeyProc.running = true
  }

  function forgetKey() {
    if (forgetProc.running) return
    root.keyMessage = ""
    root.keyOk = false
    forgetProc.running = true
  }

  function refresh(force) {
    if (statusProc.running) return
    root.loading = true
    statusProc.command = root.guarded(force
      ? [root.mayarctl, "status", "-n", "8", "-f"]
      : [root.mayarctl, "status", "-n", "8"])
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
    } else {
      // Nothing about a half-typed key should survive the panel closing.
      keyField.text = ""
      keyMessage = ""
      keyOk = false
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
        // Ages are measured against the moment the data was read, not against
        // whenever the clock below last ticked. The two are a second or two
        // apart, which is invisible in the middle of a bucket and wrong at the
        // edge of one: with floor, a payment exactly three hours old reads
        // "2h ago" if the clock is even a second behind the response.
        root.nowMs = Date.now()
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
        root.source = root.sanitise(parsed.source) || "none"
        root.env = parsed.env === "sandbox" ? "sandbox" : "production"
        root.keyringAvailable = !!parsed.keyringAvailable
        root.balance = parsed.balance || null
        root.paid = root.sanitiseRows(parsed.paid)
        root.unpaid = root.sanitiseRows(parsed.unpaid)
        root.stale = !!parsed.stale
        root.lastError = root.sanitise(parsed.error)
      }
    }
    onRunningChanged: {
      root.armDeadline(statusKill, statusProc)
      if (!running) root.loading = false
    }
  }

  Timer {
    id: statusKill
    interval: root.deadlineMs
    onTriggered: {
      statusProc.signal(9)
      statusProc.running = false
      root.loading = false
    }
  }

  // wl-copy forks into the background to serve the selection, so it is the one
  // helper that is not run under the guard: a pipe to `head` would never see
  // the end of a stream the daemonised half keeps open. Nothing reads what it
  // prints either, so it gets no collector — an unread StdioCollector is a
  // buffer that only ever grows.
  Process {
    id: copyProc
    onRunningChanged: root.armDeadline(copyKill, copyProc)
  }

  Timer {
    id: copyKill
    interval: 5000
    onTriggered: {
      copyProc.signal(9)
      copyProc.running = false
    }
  }

  // The key reaches mayarctl on stdin, never as an argument: /proc/<pid>/cmdline
  // is world-readable, so anything in argv is readable by every other user on
  // the machine for as long as the process lives. This is the same reason the
  // shell's own network panel pipes an 802.1X password to nmcli rather than
  // passing it. stdin is closed straight after the write so the `read` on the
  // other side returns instead of blocking on a pipe nobody will write to again.
  Process {
    id: setKeyProc
    property string secret: ""
    // Set when stdout has been parsed, so onExited can tell "the helper
    // answered" from "the helper never ran" and not leave Verifying… on screen.
    property bool gotResult: false

    command: root.guarded([root.mayarctl, "set-key"])
    stdinEnabled: true

    onStarted: {
      write(secret + "\n")
      secret = ""
      stdinEnabled = false
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        setKeyProc.gotResult = true
        root.savingKey = false
        var res
        try {
          res = JSON.parse(String(text || "{}"))
        } catch (e) {
          res = {}
        }
        if (res.ok) {
          root.keyOk = true
          // Storing a key that MAYAR_API_KEY then overrides looks exactly like
          // storing one that did nothing, so say which one is actually in use.
          root.keyMessage = res.shadowed
            ? "Stored — but MAYAR_API_KEY is set in the environment and outranks the keyring, so that key is still the one being used."
            : ""
          keyField.text = ""
          keyCatcher.forceActiveFocus()
          root.refresh(true)
        } else {
          root.keyOk = false
          root.keyMessage = root.sanitise(res.error) || "Could not store the key."
        }
      }
    }

    onRunningChanged: root.armDeadline(setKeyKill, setKeyProc)

    onExited: {
      if (setKeyProc.gotResult) return
      root.savingKey = false
      root.keyOk = false
      root.keyMessage = "mayarctl did not answer."
    }
  }

  Timer {
    id: setKeyKill
    interval: root.deadlineMs
    onTriggered: {
      setKeyProc.signal(9)
      setKeyProc.running = false
      // The secret is dropped in onStarted, but a helper killed before it ever
      // started still has a copy of it sitting on this object.
      setKeyProc.secret = ""
      if (!setKeyProc.gotResult) {
        root.savingKey = false
        root.keyOk = false
        root.keyMessage = "mayarctl did not answer in time."
      }
    }
  }

  Process {
    id: forgetProc
    command: root.guarded([root.mayarctl, "logout"])
    onRunningChanged: root.armDeadline(forgetKill, forgetProc)
    onExited: root.refresh(true)
  }

  Timer {
    id: forgetKill
    interval: root.deadlineMs
    onTriggered: {
      forgetProc.signal(9)
      forgetProc.running = false
    }
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
      if (!root.hasKey) return "Mayar · no API key"
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
    // With no key there is nothing else in the panel to do, so the field is
    // what the panel hands focus to on open. KeyboardPanel forces focus onto
    // this target through its own Qt.callLater when it opens, which lands
    // after anything the field could schedule for itself — so the field has to
    // be the target rather than try to take focus back afterwards. A rejected
    // key still leaves a balance and rows worth walking, so that case keeps the
    // cursor on the key catcher.
    focusTarget: !root.hasKey && root.keyringAvailable ? keyField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the key field has focus it owns every keystroke — otherwise a
      // key containing a j or a k would walk the transaction list instead of
      // being typed into the field.
      blocked: keyField.activeFocus

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
              textFormat: Text.PlainText
              text: "MAYAR"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
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

        // ---------- Key entry ----------
        //
        // There is nothing to log in to: API v2 takes an API key and nothing
        // else, so the key is typed here rather than in a terminal. It goes to
        // `mayarctl set-key` on stdin (see setKeyProc), which verifies it
        // against /balances before storing it in the login keyring — a key that
        // was never going to work does not get saved and then reported as
        // rejected on every poll afterwards.
        PanelSeparator {
          visible: root.needsKey
          foreground: root.bar.foreground
        }

        Column {
          visible: root.needsKey
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: {
              if (!root.keyringAvailable)
                return "No keyring on this machine — secret-tool, from libsecret, is not installed, " +
                       "so there is nowhere safe to put a key. Set MAYAR_API_KEY in the environment instead."
              if (root.hasKey)
                return "Mayar rejected the key from " + root.sourceLabel +
                       ". Create a new one at web.mayar.id → Integrasi › Api Keys and paste it here."
              return "Paste an API key from web.mayar.id → Integrasi › Api Keys. " +
                     "A Read Only key is enough — this widget never issues a POST. " +
                     "It is checked against your balance, then stored in your login keyring."
            }
            color: root.keyringAvailable ? Qt.darker(root.bar.foreground, 1.2) : root.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item {
            visible: root.keyringAvailable
            width: parent.width
            // The button is a fixed square and the field is sized from its
            // font; whichever wins has to be the row height, or the shorter
            // measurement lets the other one draw outside it.
            implicitHeight: Math.max(keyField.implicitHeight, saveKeyButton.implicitHeight)

            TextField {
              id: keyField
              anchors.left: parent.left
              anchors.right: saveKeyButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              password: true
              placeholderText: root.savingKey ? "Verifying…" : "Mayar API key"
              enabled: !root.savingKey
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY

              onAccepted: root.submitKey(text)
              // Whatever the line below says stopped being true the moment the
              // key changed; clear a stale rejection before it misreads as a
              // verdict on what is being typed now.
              onTextChanged: if (root.keyMessage !== "" && !root.savingKey) root.keyMessage = ""
              // Esc hands input back to the panel's own key handling, so the
              // second Esc closes the panel the way it does everywhere else.
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            PanelActionButton {
              id: saveKeyButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              enabled: !root.savingKey && keyField.text.length > 0
              iconText: "󰄬"
              tooltipText: "Verify and store this key"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.submitKey(keyField.text)
            }
          }

          Text {
            visible: root.keyMessage !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.keyMessage
            color: root.keyOk ? Qt.darker(root.bar.foreground, 1.2) : root.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
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
            textFormat: Text.PlainText
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
          // Was one line of caption text; the forget button is taller than
          // that, and nothing clips this row, so measure from whichever is
          // bigger rather than letting the button draw past the border.
          implicitHeight: Math.max(footLeft.implicitHeight + Style.space(4),
                                   forgetKeyButton.visible ? forgetKeyButton.implicitHeight : 0)

          Text {
            id: footLeft
            textFormat: Text.PlainText
            text: root.copied !== "" ? "COPIED" : ("KEY · " + root.sourceLabel.toUpperCase())
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.left: parent.left
            anchors.bottom: parent.bottom
          }

          // The key is entered in this panel, so it can be removed from it too.
          // Shown only for a key this button could actually remove: MAYAR_API_KEY
          // lives in the environment and the config file is a file, and a button
          // that silently failed to clear either would be worse than none.
          PanelActionButton {
            id: forgetKeyButton
            visible: root.source === "keyring"
            enabled: !forgetProc.running
            // The same mark the shell's own wifi panel uses for "forget this
            // network", rather than a second glyph for the same idea.
            iconText: "󰅙"
            tooltipText: "Forget the stored key"
            foreground: Qt.darker(root.bar.foreground, 1.4)
            hoverColor: root.urgent
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.body
            anchors.right: envLabel.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: envLabel.verticalCenter
            onClicked: root.forgetKey()
          }

          Text {
            id: envLabel
            textFormat: Text.PlainText
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
      textFormat: Text.PlainText
      id: balLabel
      text: balRow.label
      color: Qt.darker(root.bar.foreground, balRow.emphasised ? 1.0 : 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
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
      textFormat: Text.PlainText
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
      textFormat: Text.PlainText
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
      textFormat: Text.PlainText
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
      textFormat: Text.PlainText
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
