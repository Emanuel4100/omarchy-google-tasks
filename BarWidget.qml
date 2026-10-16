import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Google Tasks in the bar: open-task count on the icon, a panel to add, check
// off, reopen and delete tasks.
//
// All Google traffic goes through the bundled `gtasks` CLI (stdlib Python, one
// JSON object per run). `snapshot` fetches the lists and the current list's
// tasks; mutations run one at a time through `actionQueue` and update the UI
// optimistically, then a fresh snapshot reconciles. A snapshot that started
// before a mutation is discarded, so it can never undo an optimistic change.
Panel {
  id: root
  moduleName: "emanuel.gtasks"
  ipcTarget: "emanuel.gtasks"
  manageIpc: false

  readonly property string helperPath: String(Qt.resolvedUrl("gtasks")).replace(/^file:\/\//, "")
  readonly property string tokenPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/gtasks/token.json"

  // `omarchy bar set` stores plain strings, so "false" must count as false too.
  readonly property bool showCount: String(root.setting("showCount", true)) !== "false"
  readonly property int refreshMinutes: Math.max(1, Math.min(120, Math.round(Number(root.setting("refreshMinutes", 5)) || 5)))

  readonly property string iconGlyph: String.fromCodePoint(0xf0756)
  readonly property string openGlyph: String.fromCodePoint(0xf0131)
  readonly property string doneGlyph: String.fromCodePoint(0xf0135)
  readonly property string trashGlyph: String.fromCodePoint(0xf0a7a)
  readonly property string refreshGlyph: String.fromCodePoint(0xf0450)
  readonly property string webGlyph: String.fromCodePoint(0xf03cc)
  readonly property string prevGlyph: String.fromCodePoint(0xf0141)
  readonly property string nextGlyph: String.fromCodePoint(0xf0142)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- state

  property var lists: []
  property var currentList: null
  property var openTasks: []
  property var completedTasks: []
  property int completedCount: 0
  property int fetchedAt: 0
  property int nowSec: Math.floor(Date.now() / 1000)
  property bool loading: false
  property bool loadedOnce: false
  property string errorText: ""
  property string errorCode: ""
  // A failed add/check/delete. Kept apart from errorText because the
  // reconciling snapshot right after would clear that before anyone read it.
  property string actionError: ""
  property bool awaitingAuth: false
  property bool showCompleted: false
  // Unix time Google will end the sign-in, when it said so (0 = no limit
  // known). Set means the OAuth app is most likely still in "Testing".
  property int refreshExpiresAt: 0

  // Keyboard/mouse cursor over `rows`; -1 = none. `armedDelete` holds the id
  // of a task whose trash button was pressed once (press again to delete).
  property int cursor: -1
  property string armedDelete: ""
  property var pendingIds: ({})
  property int tempSeq: 0

  readonly property bool signedOut: root.errorCode === "auth_required" || root.errorCode === "auth_expired"
    || root.errorCode === "setup_required"
  readonly property int openCount: root.openTasks.length

  readonly property var rows: {
    var out = []
    for (var i = 0; i < root.openTasks.length; i++) out.push({ kind: "task", task: root.openTasks[i] })
    if (root.completedCount > 0) {
      out.push({ kind: "completedHeader" })
      if (root.showCompleted)
        for (var j = 0; j < root.completedTasks.length; j++) out.push({ kind: "task", task: root.completedTasks[j] })
    }
    return out
  }

  // ------------------------------------------------------------- text

  function widgetText() {
    if (!root.showCount || !root.loadedOnce || root.signedOut || root.openCount === 0) return root.iconGlyph
    return root.iconGlyph + " " + root.openCount
  }

  function tooltip() {
    if (root.errorCode === "setup_required") return "Google Tasks: not set up. Click for steps"
    if (root.errorCode === "auth_required") return "Google Tasks: not signed in"
    if (root.errorCode === "auth_expired") return "Google Tasks: Google ended the sign-in"
    if (!root.loadedOnce) return root.loading ? "Google Tasks: loading…" : "Google Tasks"
    var listName = root.currentList ? root.currentList.title : "Tasks"
    var text = "Google Tasks: " + root.openCount + " open in " + listName
    if (root.errorText !== "") text += " (last update failed)"
    return text
  }

  function ageText() {
    var age = root.nowSec - root.fetchedAt
    if (age < 60) return "just now"
    if (age < 3600) return Math.round(age / 60) + " min ago"
    return Math.round(age / 3600) + " h ago"
  }

  function heroMeta() {
    if (root.signedOut) return "Not connected"
    if (!root.loadedOnce) return root.loading ? "Loading…" : ""
    var parts = [root.openCount + " open"]
    parts.push(root.loading ? "syncing…" : "updated " + root.ageText())
    return parts.join(" · ")
  }

  function dueInfo(task) {
    if (!task.due) return null
    var parts = task.due.split("-")
    var due = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    var today = new Date()
    today.setHours(0, 0, 0, 0)
    var days = Math.round((due - today) / 86400000)
    var label = days === 0 ? "Today" : days === 1 ? "Tomorrow" : days === -1 ? "Yesterday"
      : (days > 1 && days < 7) ? Qt.formatDate(due, "dddd")
      : Qt.formatDate(due, due.getFullYear() === today.getFullYear() ? "ddd d MMM" : "d MMM yyyy")
    return { label: label, overdue: days < 0 && !task.completed }
  }

  function firstLine(text) {
    var s = String(text || "").trim()
    var nl = s.indexOf("\n")
    return nl >= 0 ? s.slice(0, nl) : s
  }

  // ------------------------------------------------------------- helper runs

  property var actionQueue: []
  property bool actionRunning: false
  property int mutationSeq: 0
  property int snapshotSeq: 0
  property bool snapshotWanted: false
  property var snapshotArgs: []

  function parseResult(text) {
    try {
      var data = JSON.parse(String(text || "").trim())
      if (data && typeof data === "object") return data
    } catch (e) {
    }
    return { ok: false, error: "gtasks returned no result. Run it in a terminal to see why.", code: "error" }
  }

  function refreshArgs() {
    return root.currentList ? ["snapshot", "--list", root.currentList.id] : ["snapshot"]
  }

  function refresh() {
    root.requestSnapshot(root.refreshArgs())
  }

  function requestSnapshot(args) {
    // A deferred `use` (list switch) also saves the choice; a plain refresh
    // arriving behind it must not drop that.
    if (!(root.snapshotWanted && root.snapshotArgs[0] === "use" && args[0] !== "use")) root.snapshotArgs = args
    if (snapshotProc.running || root.actionRunning || root.actionQueue.length > 0) {
      root.snapshotWanted = true
      return
    }
    root.snapshotWanted = false
    root.snapshotSeq = root.mutationSeq
    root.loading = true
    snapshotProc.args = root.snapshotArgs
    snapshotProc.command = ["python3", root.helperPath, "--json"].concat(root.snapshotArgs)
    snapshotProc.running = true
  }

  function applySnapshot(data) {
    root.loading = false
    if (root.snapshotSeq !== root.mutationSeq || root.snapshotWanted) {
      // A mutation started while this was in flight; its result may be stale.
      var again = root.snapshotWanted ? root.snapshotArgs : snapshotProc.args
      root.snapshotWanted = false
      Qt.callLater(root.requestSnapshot, again)
      return
    }
    if (!data.ok) {
      root.errorText = String(data.error || "Unknown error")
      root.errorCode = String(data.code || "error")
      return
    }
    root.errorText = ""
    root.errorCode = ""
    root.lists = data.lists || []
    root.currentList = data.list || null
    root.openTasks = data.open || []
    root.completedTasks = data.completed || []
    root.completedCount = Number(data.completedCount || 0)
    root.refreshExpiresAt = Number(data.refreshExpiresAt || 0)
    root.fetchedAt = Number(data.fetched || 0)
    root.nowSec = Math.floor(Date.now() / 1000)
    root.loadedOnce = true
    root.awaitingAuth = false
    root.clampCursor()
  }

  function enqueue(args, onResult) {
    root.mutationSeq++
    var q = root.actionQueue.slice()
    q.push({ args: args, onResult: onResult })
    root.actionQueue = q
    root.pumpQueue()
  }

  function pumpQueue() {
    if (root.actionRunning || root.actionQueue.length === 0) return
    var job = root.actionQueue[0]
    root.actionRunning = true
    actionProc.onResult = job.onResult
    actionProc.command = ["python3", root.helperPath, "--json"].concat(job.args)
    actionProc.running = true
  }

  function finishAction(text) {
    var data = root.parseResult(text)
    var handler = actionProc.onResult
    var q = root.actionQueue.slice()
    q.shift()
    root.actionQueue = q
    root.actionRunning = false
    if (handler) handler(data)
    if (!data.ok) {
      if (data.code === "auth_required" || data.code === "auth_expired" || data.code === "setup_required") {
        root.errorText = String(data.error || "")
        root.errorCode = String(data.code)
      } else {
        root.actionError = String(data.error || "Unknown error")
        actionErrorTimer.restart()
      }
    }
    if (root.actionQueue.length > 0) root.pumpQueue()
    else settleTimer.restart()
  }

  function listArgs() {
    return root.currentList ? ["--list-id", root.currentList.id] : []
  }

  function setPending(id, on) {
    var p = Object.assign({}, root.pendingIds)
    if (on) p[id] = true
    else delete p[id]
    root.pendingIds = p
  }

  // ------------------------------------------------------------- actions

  function addTask(title) {
    title = String(title || "").trim()
    if (title === "" || !root.currentList) return
    var tempId = "pending-" + (++root.tempSeq)
    var temp = { id: tempId, title: title, notes: "", due: "", completed: false, completedAt: "", parent: "", depth: 0 }
    // Google puts new tasks at the top of the list.
    root.openTasks = [temp].concat(root.openTasks)
    root.setPending(tempId, true)
    root.enqueue(["add", title].concat(root.listArgs()), function(data) {
      root.setPending(tempId, false)
      var tasks = root.openTasks.slice()
      for (var i = 0; i < tasks.length; i++) {
        if (tasks[i].id !== tempId) continue
        if (data.ok && data.task) tasks[i] = data.task
        else {
          tasks.splice(i, 1)
          if (addField.text === "") addField.text = title
        }
        break
      }
      root.openTasks = tasks
    })
  }

  function setDone(task, done) {
    if (!task || root.pendingIds[task.id] || task.id.indexOf("pending-") === 0) return
    var openList = root.openTasks.slice()
    var doneList = root.completedTasks.slice()
    var moved = Object.assign({}, task, { completed: done, depth: done ? 0 : task.depth })
    if (done) {
      openList = openList.filter(function(t) { return t.id !== task.id })
      doneList = [moved].concat(doneList)
      root.completedCount++
    } else {
      doneList = doneList.filter(function(t) { return t.id !== task.id })
      openList = [moved].concat(openList)
      root.completedCount = Math.max(0, root.completedCount - 1)
    }
    root.openTasks = openList
    root.completedTasks = doneList
    root.setPending(task.id, true)
    root.clampCursor()
    root.enqueue([done ? "done" : "undo", task.id].concat(root.listArgs()), function(data) {
      root.setPending(task.id, false)
    })
  }

  function deleteTask(task) {
    if (!task || root.pendingIds[task.id] || task.id.indexOf("pending-") === 0) return
    if (root.armedDelete !== task.id) {
      root.armedDelete = task.id
      disarmTimer.restart()
      return
    }
    root.armedDelete = ""
    if (task.completed) {
      root.completedTasks = root.completedTasks.filter(function(t) { return t.id !== task.id })
      root.completedCount = Math.max(0, root.completedCount - 1)
    } else {
      root.openTasks = root.openTasks.filter(function(t) { return t.id !== task.id })
    }
    root.clampCursor()
    root.enqueue(["delete", task.id].concat(root.listArgs()), function(data) {})
  }

  function switchList(step) {
    if (root.lists.length < 2 || !root.currentList) return
    var idx = 0
    for (var i = 0; i < root.lists.length; i++) if (root.lists[i].id === root.currentList.id) idx = i
    var next = root.lists[(idx + step + root.lists.length) % root.lists.length]
    root.currentList = next
    root.openTasks = []
    root.completedTasks = []
    root.completedCount = 0
    root.cursor = -1
    root.requestSnapshot(["use", next.id])
  }

  function activateRow(index) {
    var row = root.rows[index]
    if (!row) return
    if (row.kind === "completedHeader") root.showCompleted = !root.showCompleted
    else root.setDone(row.task, !row.task.completed)
  }

  function signIn() {
    root.close()
    root.awaitingAuth = true
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "python3 '" + root.helperPath + "' auth"])
  }

  function openWeb() {
    root.close()
    Quickshell.execDetached(["xdg-open", "https://tasks.google.com/"])
  }

  function clampCursor() {
    if (root.cursor >= root.rows.length) root.cursor = root.rows.length - 1
  }

  function moveCursor(dy) {
    if (root.rows.length === 0) return
    if (root.cursor < 0) {
      root.cursor = dy > 0 ? 0 : root.rows.length - 1
      return
    }
    var next = root.cursor + dy
    if (next < 0) {
      root.cursor = -1
      addField.forceActiveFocus()
      return
    }
    root.cursor = Math.min(root.rows.length - 1, next)
  }

  function focusAdd() {
    // Hidden while signed out or before the first load. Focusing it then
    // would block keyCatcher, and Esc would stop closing the panel.
    if (!addField.visible) return
    root.cursor = -1
    addField.forceActiveFocus()
  }

  function leaveAdd() {
    keyCatcher.forceActiveFocus()
  }

  // ------------------------------------------------------------- lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: root.refresh()

  onOpenedChanged: {
    if (opened) {
      root.cursor = -1
      root.armedDelete = ""
      root.nowSec = Math.floor(Date.now() / 1000)
      if (root.nowSec - root.fetchedAt > 30) root.refresh()
    } else {
      root.showCompleted = false
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Open the panel with the cursor in the "Add a task" field.
    function compose(): void { root.compose() }
    function refresh(): void { root.refresh() }
  }

  Process {
    id: snapshotProc
    property var args: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySnapshot(root.parseResult(text))
    }
  }

  Process {
    id: actionProc
    property var onResult: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishAction(text)
    }
  }

  // A burst of checkmarks becomes one reconciling snapshot.
  Timer {
    id: settleTimer
    interval: 700
    onTriggered: root.requestSnapshot(root.snapshotWanted ? root.snapshotArgs : root.refreshArgs())
  }

  Timer {
    interval: root.refreshMinutes * 60000
    running: true
    repeat: true
    onTriggered: if (!root.signedOut) root.refresh()
  }

  // Keeps "updated N min ago" current while the panel is open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  Timer {
    id: actionErrorTimer
    interval: 8000
    onTriggered: root.actionError = ""
  }

  // After "Connect", poll until the sign-in in the terminal lands (5 min cap).
  Timer {
    id: authPoll
    interval: 3000
    repeat: true
    running: root.awaitingAuth
    property int ticks: 0
    onRunningChanged: ticks = 0
    onTriggered: {
      if (++ticks > 100) root.awaitingAuth = false
      else if (!snapshotProc.running) root.refresh()
    }
  }

  Timer {
    id: disarmTimer
    interval: 3000
    onTriggered: root.armedDelete = ""
  }

  // The panel grabs focus for its key catcher right after it maps; take the
  // field after that.
  Timer {
    id: composeTimer
    interval: 120
    onTriggered: root.focusAdd()
  }

  // Signing in happens in a terminal; pick the new token up as soon as it lands.
  FileView {
    path: root.tokenPath
    watchChanges: true
    printErrors: false
    onFileChanged: if (root.signedOut) root.refresh()
  }

  // ------------------------------------------------------------- bar button

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.widgetText()
    fontSize: Style.bar.iconFont
    foreground: root.signedOut || (root.errorText !== "" && !root.loadedOnce) ? Color.muted : root.barForeground
    dimmed: root.loading && !root.loadedOnce
    tooltipText: root.tooltip()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) root.compose()
      else root.toggle()
    }
  }

  // Open with the cursor in "Add a task"; close if already open. Bound to
  // SUPER+SHIFT+T and the bar icon's middle click.
  function compose() {
    if (root.opened) {
      root.close()
      return
    }
    root.open()
    composeTimer.restart()
  }

  // ------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus

      onCloseRequested: {
        if (root.armedDelete !== "") root.armedDelete = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.switchList(dx)
        else root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursor >= 0) root.activateRow(root.cursor)
      onDeleteRequested: {
        var row = root.rows[root.cursor]
        if (row && row.kind === "task") root.deleteTask(row.task)
      }
      onTextKey: function(t) {
        if (t === "a" || t === "i" || t === "o" || t === "/") root.focusAdd()
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "c") root.showCompleted = !root.showCompleted
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: root.currentList ? root.currentList.title : "Google Tasks"
          meta: root.heroMeta()
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.loading ? 0.45 : 1.0
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.iconGlyph
              color: root.signedOut ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.space(2)
              PanelActionButton {
                visible: root.lists.length > 1
                iconText: root.prevGlyph
                tooltipText: "Previous list (h)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.switchList(-1)
              }
              PanelActionButton {
                visible: root.lists.length > 1
                iconText: root.nextGlyph
                tooltipText: "Next list (l)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.switchList(1)
              }
              PanelActionButton {
                iconText: root.refreshGlyph
                tooltipText: "Refresh (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.loading
                onClicked: root.refresh()
              }
              PanelActionButton {
                iconText: root.webGlyph
                tooltipText: "Open Google Tasks in the browser"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openWeb()
              }
            }
          }
        }

        // ---- not connected

        Column {
          visible: root.signedOut
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: root.errorCode === "setup_required"
              ? "One-time setup: in Google Cloud Console, enable the Google Tasks API, create an OAuth client of type \"Desktop app\", and save its JSON as ~/.config/gtasks/client_secret.json. Then connect below."
              : root.errorCode === "auth_expired" ? root.errorText
              : "Sign in to your Google account to load your tasks."
          }

          Button {
            text: "Connect Google account"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.signIn()
          }
        }

        // ---- error banner (signed in, but the last call failed)

        Text {
          textFormat: Text.PlainText
          visible: text !== "" && !root.signedOut
          width: parent.width
          text: root.actionError !== "" ? "Couldn't save that change: " + root.actionError
            : root.errorText === "" ? ""
            : root.errorCode === "offline" ? "Offline. Showing the last tasks fetched."
            : root.errorText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: root.refreshExpiresAt > 0 && !root.signedOut
          width: parent.width
          text: {
            var days = Math.max(1, Math.round((root.refreshExpiresAt - root.nowSec) / 86400))
            return "Sign-in expires in " + days + (days === 1 ? " day" : " days")
              + ". Publish the OAuth app (Google Auth Platform > Audience) to stop this."
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---- add

        TextField {
          id: addField
          visible: !root.signedOut && root.loadedOnce
          width: parent.width
          placeholderText: "Add a task (a)"
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          onAccepted: {
            var title = text
            text = ""
            root.addTask(title)
          }
          Keys.onEscapePressed: function(event) {
            if (text !== "") text = ""
            else root.leaveAdd()
            event.accepted = true
          }
          Keys.onDownPressed: function(event) {
            root.leaveAdd()
            root.moveCursor(1)
            event.accepted = true
          }
          Keys.onTabPressed: function(event) {
            root.leaveAdd()
            root.switchPanel(1)
            event.accepted = true
          }
          onActiveFocusChanged: if (activeFocus) root.cursor = -1
        }

        // ---- tasks

        ListView {
          id: taskList
          visible: !root.signedOut && root.loadedOnce && root.rows.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(440))
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.rows
          currentIndex: root.cursor
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Loader {
            id: rowLoader
            required property var modelData
            required property int index
            width: ListView.view.width
            sourceComponent: modelData.kind === "completedHeader" ? completedHeaderRow : taskRow

            Component {
              id: taskRow
              TaskRow { task: rowLoader.modelData.task; rowIndex: rowLoader.index }
            }
            Component {
              id: completedHeaderRow
              CompletedHeader { rowIndex: rowLoader.index }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.signedOut && root.loadedOnce && root.rows.length === 0
          width: parent.width
          text: "No tasks. Nice."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.signedOut && root.loadedOnce
          width: parent.width
          text: "space: check · x: delete · a: add · h/l: list · c: completed"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ------------------------------------------------------------- rows

  component TaskRow: CursorSurface {
    id: row
    required property var task
    required property int rowIndex

    readonly property bool pending: !!root.pendingIds[task.id]
    readonly property bool armed: root.armedDelete === task.id
    readonly property var due: root.dueInfo(task)
    readonly property string note: root.firstLine(task.notes)
    readonly property real indent: Math.min(3, task.depth || 0) * Style.space(18)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Style.space(32), labels.implicitHeight + Style.space(12))
    hasCursor: root.cursor === rowIndex
    foreground: root.foreground

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = row.rowIndex
      onClicked: root.setDone(row.task, !row.task.completed)
    }

    Text {
      id: check
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8) + row.indent
      anchors.verticalCenter: parent.verticalCenter
      text: row.task.completed ? root.doneGlyph : root.openGlyph
      color: row.task.completed ? root.dim : root.foreground
      opacity: row.pending ? 0.45 : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    Column {
      id: labels
      anchors.left: check.right
      anchors.leftMargin: Style.space(10)
      anchors.right: trash.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.task.title
        color: row.task.completed ? root.dim : root.foreground
        opacity: row.pending ? 0.6 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: row.task.completed
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: {
          var bits = []
          if (row.due) bits.push(row.due.label)
          if (row.note !== "") bits.push(row.note)
          return bits.join(" · ")
        }
        color: row.due && row.due.overdue ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      id: trash
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      visible: !row.pending && row.task.id.indexOf("pending-") !== 0
      opacity: row.armed || row.hasCursor ? 1.0 : 0.0
      iconText: root.trashGlyph
      tooltipText: row.armed ? "Click again to delete" : "Delete (x)"
      foreground: row.armed ? root.urgent : root.dim
      hoverColor: root.urgent
      fontFamily: root.fontFamily
      onHovered: function(isHovered) { if (isHovered) root.cursor = row.rowIndex }
      onClicked: root.deleteTask(row.task)
    }
  }

  component CompletedHeader: CursorSurface {
    id: header
    required property int rowIndex

    width: parent ? parent.width : 0
    implicitHeight: Style.space(30)
    hasCursor: root.cursor === rowIndex
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = header.rowIndex
      onClicked: root.showCompleted = !root.showCompleted
    }

    PanelSectionHeader {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: (root.showCompleted ? "▾ " : "▸ ") + "Completed (" + root.completedCount + ")"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }
}
