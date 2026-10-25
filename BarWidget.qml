import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "i18n.js" as I18n

// Google Tasks in the bar: open-task count on the icon, a panel to add, check
// off, reopen, edit and delete tasks.
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
  // The plugin's own settings (language), kept out of shell.json so picking a
  // language from the panel doesn't rewrite the shell config.
  readonly property string settingsDir: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/gtasks"

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
  readonly property string editGlyph: String.fromCodePoint(0xf03eb)
  readonly property string languageGlyph: String.fromCodePoint(0xf05ca)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- language

  // "system" or a language code from i18n.js; saved in settings.json.
  property string languagePref: "system"
  property var savedSettings: ({})
  readonly property string systemLang: {
    var code = Qt.locale().name.slice(0, 2)
    if (code === "iw") code = "he"
    return I18n.has(code) ? code : "en"
  }
  readonly property string lang: root.languagePref === "system" ? root.systemLang : root.languagePref
  readonly property bool rtl: I18n.isRtl(root.lang)
  readonly property var dateLocale: root.lang === root.systemLang ? Qt.locale() : Qt.locale(I18n.locale(root.lang))
  readonly property var languageChoices: ["system"].concat(I18n.languages())

  function tr(key) {
    return I18n.tr(root.lang, key, Array.prototype.slice.call(arguments, 1))
  }

  function languageLabel(pref) {
    return pref === "system" ? root.tr("languageSystem", I18n.names[root.systemLang]) : I18n.names[pref]
  }

  function cycleLanguage() {
    var i = root.languageChoices.indexOf(root.languagePref)
    root.setLanguage(root.languageChoices[(i + 1) % root.languageChoices.length])
  }

  function setLanguage(pref) {
    root.languagePref = pref
    root.savedSettings = Object.assign({}, root.savedSettings, { language: pref })
    settingsDirProc.pendingText = JSON.stringify(root.savedSettings, null, 2) + "\n"
    settingsDirProc.running = true
  }

  function loadSettings(raw) {
    var data = null
    try {
      data = JSON.parse(String(raw || ""))
    } catch (e) {
    }
    if (!data || typeof data !== "object") data = {}
    root.savedSettings = data
    var pref = String(data.language || "system")
    root.languagePref = pref === "system" || I18n.has(pref) ? pref : "system"
  }

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
  // Task whose title is being edited in its row, and the text typed so far.
  property string editingId: ""
  property string editDraft: ""
  // Rows playing their exit animation, id -> "done" | "undo" | "delete". The
  // arrays change only once the animation has finished (see setDone).
  property var leaving: ({})

  readonly property bool signedOut: root.errorCode === "auth_required" || root.errorCode === "auth_expired"
    || root.errorCode === "setup_required"
  readonly property int openCount: root.openTasks.length

  // `key` lets the ScriptModel keep a row's delegate across updates, so an
  // exit animation isn't cut short when another row changes.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < root.openTasks.length; i++)
      out.push({ key: root.openTasks[i].id, kind: "task", task: root.openTasks[i] })
    if (root.completedCount > 0) {
      out.push({ key: "completedHeader", kind: "completedHeader" })
      if (root.showCompleted)
        for (var j = 0; j < root.completedTasks.length; j++)
          out.push({ key: root.completedTasks[j].id, kind: "task", task: root.completedTasks[j] })
    }
    return out
  }

  // ------------------------------------------------------------- text

  function widgetText() {
    if (!root.showCount || !root.loadedOnce || root.signedOut || root.openCount === 0) return root.iconGlyph
    return root.iconGlyph + " " + root.openCount
  }

  function tooltip() {
    if (root.errorCode === "setup_required") return root.tr("tooltipSetup")
    if (root.errorCode === "auth_required") return root.tr("tooltipSignedOut")
    if (root.errorCode === "auth_expired") return root.tr("tooltipExpired")
    if (!root.loadedOnce) return root.loading ? root.tr("tooltipLoading") : root.tr("appName")
    var listName = root.currentList ? root.currentList.title : root.tr("defaultList")
    var text = root.tr("tooltipCount", root.openCount, listName)
    if (root.errorText !== "") text += root.tr("tooltipFailed")
    return text
  }

  function ageText() {
    var age = root.nowSec - root.fetchedAt
    if (age < 60) return root.tr("justNow")
    if (age < 3600) return root.tr("minAgo", Math.round(age / 60))
    return root.tr("hoursAgo", Math.round(age / 3600))
  }

  function heroMeta() {
    if (root.signedOut) return root.tr("notConnected")
    if (!root.loadedOnce) return root.loading ? root.tr("loading") : ""
    var parts = [root.tr("openCount", root.openCount)]
    parts.push(root.loading ? root.tr("syncing") : root.tr("updated", root.ageText()))
    return parts.join(" · ")
  }

  function dueInfo(task) {
    if (!task.due) return null
    var parts = task.due.split("-")
    var due = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    var today = new Date()
    today.setHours(0, 0, 0, 0)
    var days = Math.round((due - today) / 86400000)
    var label = days === 0 ? root.tr("today") : days === 1 ? root.tr("tomorrow") : days === -1 ? root.tr("yesterday")
      : (days > 1 && days < 7) ? due.toLocaleDateString(root.dateLocale, "dddd")
      : due.toLocaleDateString(root.dateLocale, due.getFullYear() === today.getFullYear() ? "ddd d MMM" : "d MMM yyyy")
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
    return { ok: false, error: root.tr("noResult"), code: "error" }
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
    // Also wait while a title is being edited: a fresh list could drop the
    // row under the field. endEdit() runs it.
    if (snapshotProc.running || root.actionRunning || root.actionQueue.length > 0 || root.editingId !== "") {
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
      root.errorText = String(data.error || root.tr("unknownError"))
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
        root.actionError = data.code === "offline" ? root.tr("noConnection") : String(data.error || root.tr("unknownError"))
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

  function setLeaving(id, kind) {
    var l = Object.assign({}, root.leaving)
    if (kind) l[id] = kind
    else delete l[id]
    root.leaving = l
  }

  // Busy rows ignore check/delete/edit until their change has gone through.
  function busy(task) {
    return !task || !!root.pendingIds[task.id] || !!root.leaving[task.id] || task.id.indexOf("pending-") === 0
  }

  function findTask(list, id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  function replaceTask(id, changes) {
    function patch(t) { return t.id === id ? Object.assign({}, t, changes) : t }
    root.openTasks = root.openTasks.map(patch)
    root.completedTasks = root.completedTasks.map(patch)
  }

  // Runs fn after ms. The timer belongs to root, so the commit still happens
  // if the row that started the animation is gone by then.
  function after(ms, fn) {
    delayTimer.createObject(root, { interval: ms, callback: fn, running: true })
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

  // The row plays its check-off animation (TaskRow transitions) while the
  // change is already on its way to Google; the task moves between the open
  // and completed lists once the row has faded out.
  readonly property int doneAnimMs: 620
  readonly property int deleteAnimMs: 360

  function setDone(task, done) {
    if (root.busy(task)) return
    root.setPending(task.id, true)
    root.setLeaving(task.id, done ? "done" : "undo")
    root.enqueue([done ? "done" : "undo", task.id].concat(root.listArgs()), function(data) {
      root.setPending(task.id, false)
    })
    root.after(root.doneAnimMs, function() { root.commitDone(task.id, done) })
  }

  function commitDone(id, done) {
    root.setLeaving(id, "")
    // Gone already: the list was switched, or a snapshot moved it.
    var task = root.findTask(done ? root.openTasks : root.completedTasks, id)
    if (!task) return
    var moved = Object.assign({}, task, { completed: done, depth: done ? 0 : task.depth })
    if (done) {
      root.openTasks = root.openTasks.filter(function(t) { return t.id !== id })
      root.completedTasks = [moved].concat(root.completedTasks)
      root.completedCount++
    } else {
      root.completedTasks = root.completedTasks.filter(function(t) { return t.id !== id })
      root.openTasks = [moved].concat(root.openTasks)
      root.completedCount = Math.max(0, root.completedCount - 1)
    }
    root.clampCursor()
  }

  function deleteTask(task) {
    if (root.busy(task)) return
    if (root.armedDelete !== task.id) {
      root.armedDelete = task.id
      disarmTimer.restart()
      return
    }
    root.armedDelete = ""
    root.setLeaving(task.id, "delete")
    root.enqueue(["delete", task.id].concat(root.listArgs()), function(data) {})
    root.after(root.deleteAnimMs, function() { root.commitDelete(task.id) })
  }

  function commitDelete(id) {
    root.setLeaving(id, "")
    if (root.findTask(root.completedTasks, id)) {
      root.completedTasks = root.completedTasks.filter(function(t) { return t.id !== id })
      root.completedCount = Math.max(0, root.completedCount - 1)
    } else {
      root.openTasks = root.openTasks.filter(function(t) { return t.id !== id })
    }
    root.clampCursor()
  }

  function startEdit(task) {
    if (root.busy(task) || root.editingId !== "") return
    root.armedDelete = ""
    root.editDraft = task.title
    root.editingId = task.id
  }

  function saveEdit(task, text) {
    var title = String(text || "").trim()
    var old = task.title
    if (title !== "" && title !== old) {
      root.replaceTask(task.id, { title: title })
      root.setPending(task.id, true)
      root.enqueue(["edit", task.id, "--title", title].concat(root.listArgs()), function(data) {
        root.setPending(task.id, false)
        if (!data.ok) root.replaceTask(task.id, { title: old })
      })
    }
    root.endEdit()
  }

  // Saves nothing: Enter goes through saveEdit, Esc and clicking away end here.
  function endEdit() {
    if (root.editingId === "") return
    root.editingId = ""
    root.editDraft = ""
    if (root.opened && !addField.activeFocus) keyCatcher.forceActiveFocus()
    if (root.snapshotWanted) root.requestSnapshot(root.snapshotArgs)
  }

  function switchList(step) {
    if (root.lists.length < 2 || !root.currentList) return
    var idx = 0
    for (var i = 0; i < root.lists.length; i++) if (root.lists[i].id === root.currentList.id) idx = i
    var next = root.lists[(idx + step + root.lists.length) % root.lists.length]
    root.endEdit()
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

  // xkb keycodes (evdev + 8) of the US-QWERTY keys the panel binds. On a
  // non-Latin layout (Hebrew: j types "ח") event.text matches none of them,
  // so those keys are read by physical position instead.
  readonly property var qwertyKeys: ({ 38: "a", 54: "c", 26: "e", 43: "h", 31: "i", 44: "j",
    45: "k", 46: "l", 32: "o", 27: "r", 53: "x", 61: "/" })

  function latinKey(event) {
    var t = event.text || ""
    // Any Latin layout (QWERTY, Dvorak, Colemak…) keeps its own letters.
    if (/^[A-Za-z]$/.test(t)) return t
    var k = root.qwertyKeys[event.nativeScanCode]
    if (k === undefined) return t
    return (event.modifiers & Qt.ShiftModifier) ? k.toUpperCase() : k
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
      root.endEdit()
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

  // One-shot timers made by after().
  Component {
    id: delayTimer
    Timer {
      property var callback: null
      onTriggered: {
        callback()
        destroy()
      }
    }
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

  // A missing file means "system" (loadFailed leaves the default alone).
  FileView {
    id: settingsFile
    path: root.settingsDir + "/settings.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onFileChanged: reload()
  }

  // ~/.config/gtasks may not exist yet (no client JSON saved). The CLI
  // creates it 0700 because the client secret lives there too.
  Process {
    id: settingsDirProc
    property string pendingText: ""
    command: ["mkdir", "-p", "-m", "700", root.settingsDir]
    onExited: settingsFile.setText(pendingText)
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

    LayoutKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus || root.editingId !== ""
      LayoutMirroring.enabled: root.rtl
      LayoutMirroring.childrenInherit: true

      onCloseRequested: {
        if (root.armedDelete !== "") root.armedDelete = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        // Left/h always goes to the list whose button sits on the left,
        // which in a right-to-left panel is the next one.
        if (dx !== 0) root.switchList(root.rtl ? -dx : dx)
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
        else if (t === "e") {
          var row = root.rows[root.cursor]
          if (row && row.kind === "task") root.startEdit(row.task)
        }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: root.currentList ? root.currentList.title : root.tr("appName")
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
              // The Row mirrors in right-to-left, which puts "previous" on
              // the right; its chevron has to point right to match.
              PanelActionButton {
                visible: root.lists.length > 1
                iconText: root.rtl ? root.nextGlyph : root.prevGlyph
                tooltipText: root.tr("prevList", root.rtl ? "l" : "h")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.switchList(-1)
              }
              PanelActionButton {
                visible: root.lists.length > 1
                iconText: root.rtl ? root.prevGlyph : root.nextGlyph
                tooltipText: root.tr("nextList", root.rtl ? "h" : "l")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.switchList(1)
              }
              PanelActionButton {
                iconText: root.refreshGlyph
                tooltipText: root.tr("refresh")
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.loading
                onClicked: root.refresh()
              }
              PanelActionButton {
                iconText: root.languageGlyph
                tooltipText: root.tr("language", root.languageLabel(root.languagePref))
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.cycleLanguage()
              }
              PanelActionButton {
                iconText: root.webGlyph
                tooltipText: root.tr("openWeb")
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
            text: root.errorCode === "setup_required" ? root.tr("setupText")
              : root.errorCode === "auth_expired" ? root.tr("expiredText")
              : root.tr("signInText")
          }

          Button {
            text: root.tr("connect")
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
          text: root.actionError !== "" ? root.tr("saveFailed", root.actionError)
            : root.errorText === "" ? ""
            : root.errorCode === "offline" ? root.tr("offline")
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
            return days === 1 ? root.tr("expiresOne") : root.tr("expiresMany", days)
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
          placeholderText: root.tr("addPlaceholder")
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

          model: ScriptModel {
            values: root.rows
            objectProp: "key"
          }
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
          text: root.tr("noTasks")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.signedOut && root.loadedOnce
          width: parent.width
          text: root.tr("hints")
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
    readonly property bool editing: root.editingId === task.id
    readonly property bool temporary: task.id.indexOf("pending-") === 0
    // "done" | "undo" | "delete" while the row animates out, else "".
    readonly property string leaveKind: root.leaving[task.id] || ""
    // Checking off flips the glyph at once; the task moves lists after the fade.
    readonly property bool looksDone: row.leaveKind === "done" ? true : row.leaveKind === "undo" ? false : task.completed
    readonly property var due: root.dueInfo(task)
    readonly property string note: root.firstLine(task.notes)
    readonly property real indent: Math.min(3, task.depth || 0) * Style.space(18)

    // Exit animation: collapse 1 -> 0 folds the row away, slide pushes it
    // toward the trash button.
    property real collapse: 1
    property real slide: 0

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Style.space(32), labels.implicitHeight + Style.space(12)) * row.collapse
    clip: true
    hasCursor: root.cursor === rowIndex && row.leaveKind === ""
    foreground: root.foreground
    transform: Translate { x: row.slide }

    states: [
      State {
        name: "checked"
        when: row.leaveKind === "done" || row.leaveKind === "undo"
        PropertyChanges { target: row; collapse: 0; opacity: 0 }
      },
      State {
        name: "deleted"
        when: row.leaveKind === "delete"
        // Transforms don't mirror with the layout, so flip by hand.
        PropertyChanges { target: row; collapse: 0; opacity: 0; slide: (root.rtl ? -1 : 1) * Style.space(40) }
      }
    ]

    // Both finish before root.doneAnimMs / deleteAnimMs commit the change.
    transitions: [
      Transition {
        to: "checked"
        SequentialAnimation {
          NumberAnimation { target: check; property: "scale"; to: 1.3; duration: 90; easing.type: Easing.OutCubic }
          NumberAnimation { target: check; property: "scale"; to: 1; duration: 130; easing.type: Easing.OutCubic }
          PauseAnimation { duration: 140 }
          NumberAnimation { properties: "collapse,opacity"; duration: 220; easing.type: Easing.OutCubic }
        }
      },
      Transition {
        to: "deleted"
        SequentialAnimation {
          NumberAnimation { properties: "slide,opacity"; duration: 180; easing.type: Easing.OutCubic }
          NumberAnimation { properties: "collapse"; duration: 160; easing.type: Easing.OutCubic }
        }
      }
    ]

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      enabled: !row.editing
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = row.rowIndex
      onClicked: {
        // A click elsewhere while editing only ends the edit.
        if (root.editingId !== "") root.endEdit()
        else root.setDone(row.task, !row.task.completed)
      }
    }

    Text {
      id: check
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8) + row.indent
      anchors.verticalCenter: parent.verticalCenter
      text: row.looksDone ? root.doneGlyph : root.openGlyph
      color: row.looksDone ? root.dim : root.foreground
      opacity: row.pending && row.leaveKind === "" ? 0.45 : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    Column {
      id: labels
      anchors.left: check.right
      anchors.leftMargin: Style.space(10)
      anchors.right: row.editing ? parent.right : editButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        visible: !row.editing
        width: parent.width
        text: row.task.title
        color: row.looksDone ? root.dim : root.foreground
        opacity: row.pending && row.leaveKind === "" ? 0.6 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: row.looksDone
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Loader {
        active: row.editing
        visible: active
        width: parent.width
        sourceComponent: TextField {
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Component.onCompleted: {
            text = root.editDraft
            selectAll()
            forceActiveFocus()
          }
          onTextChanged: root.editDraft = text
          onAccepted: root.saveEdit(row.task, text)
          // Clicking the add field or another row ends the edit. Later,
          // so the new focus holder has it before endEdit looks.
          onActiveFocusChanged: if (!activeFocus) Qt.callLater(root.endEdit)
          Keys.onEscapePressed: function(event) {
            root.endEdit()
            event.accepted = true
          }
          Keys.onTabPressed: function(event) { event.accepted = true }
        }
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
      id: editButton
      anchors.right: trash.left
      anchors.verticalCenter: parent.verticalCenter
      visible: trash.visible
      opacity: row.hasCursor && !row.armed ? 1.0 : 0.0
      iconText: root.editGlyph
      tooltipText: root.tr("edit")
      foreground: root.dim
      hoverColor: root.foreground
      fontFamily: root.fontFamily
      onHovered: function(isHovered) { if (isHovered) root.cursor = row.rowIndex }
      onClicked: root.startEdit(row.task)
    }

    PanelActionButton {
      id: trash
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      visible: !row.pending && !row.temporary && !row.editing
      opacity: row.armed || row.hasCursor ? 1.0 : 0.0
      iconText: root.trashGlyph
      tooltipText: row.armed ? root.tr("deleteConfirm") : root.tr("delete")
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
      text: (root.showCompleted ? "▾ " : root.rtl ? "◂ " : "▸ ") + root.tr("completed", root.completedCount)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  // PanelKeyCatcher (qs.Ui) with the same signals, except letters go through
  // latinKey(). PanelKeyCatcher matches event.text, so on the Hebrew layout
  // j arrives as "ח" and none of the panel's letter keys did anything.
  component LayoutKeyCatcher: Item {
    id: catcher

    property bool blocked: false

    signal moveRequested(int dx, int dy)
    signal activateRequested()
    signal closeRequested()
    signal deleteRequested()
    signal tabRequested(int direction)
    signal textKey(string text)

    focus: true
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (catcher.blocked) return
      var t = root.latinKey(event)

      if (event.key === Qt.Key_Escape) {
        catcher.closeRequested(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        catcher.tabRequested((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Down || t === "j") {
        catcher.moveRequested(0, 1); event.accepted = true; return
      }
      if (event.key === Qt.Key_Up || t === "k") {
        catcher.moveRequested(0, -1); event.accepted = true; return
      }
      if (event.key === Qt.Key_Right || t === "l") {
        catcher.moveRequested(1, 0); event.accepted = true; return
      }
      if (event.key === Qt.Key_Left || t === "h") {
        catcher.moveRequested(-1, 0); event.accepted = true; return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        catcher.activateRequested(); event.accepted = true; return
      }
      if (t === "x" || t === "X") {
        catcher.deleteRequested(); event.accepted = true; return
      }
      if (t.length === 1) catcher.textKey(t)
    }
  }
}
