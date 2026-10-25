.pragma library

// UI strings for the Google Tasks widget, one block per language. To add a
// language, copy the `en` block, translate the values, and add the language
// to `names` and `locales` (plus `rtl` if it is written right to left).
// A key missing from a block falls back to English. tr() fills {0}, {1}, …

var names = { en: "English", he: "עברית" }
var locales = { en: "en_US", he: "he_IL" }
var rtl = { he: true }

var strings = {
  en: {
    appName: "Google Tasks",
    defaultList: "Tasks",
    tooltipSetup: "Google Tasks: not set up. Click for steps",
    tooltipSignedOut: "Google Tasks: not signed in",
    tooltipExpired: "Google Tasks: Google ended the sign-in",
    tooltipLoading: "Google Tasks: loading…",
    tooltipCount: "Google Tasks: {0} open in {1}",
    tooltipFailed: " (last update failed)",
    justNow: "just now",
    minAgo: "{0} min ago",
    hoursAgo: "{0} h ago",
    notConnected: "Not connected",
    loading: "Loading…",
    openCount: "{0} open",
    syncing: "syncing…",
    updated: "updated {0}",
    today: "Today",
    tomorrow: "Tomorrow",
    yesterday: "Yesterday",
    noResult: "gtasks returned no result. Run it in a terminal to see why.",
    unknownError: "Unknown error",
    noConnection: "no connection",
    prevList: "Previous list ({0})",
    nextList: "Next list ({0})",
    refresh: "Refresh (r)",
    openWeb: "Open Google Tasks in the browser",
    language: "Language: {0}",
    languageSystem: "System ({0})",
    setupText: "One-time setup: in Google Cloud Console, enable the Google Tasks API, create an OAuth client of type \"Desktop app\", and save its JSON as ~/.config/gtasks/client_secret.json. Then connect below.",
    expiredText: "Google ended the sign-in. If this happens about every 7 days, the OAuth app is still in Testing: publish it (Google Auth Platform > Audience > Publish app), then reconnect.",
    signInText: "Sign in to your Google account to load your tasks.",
    connect: "Connect Google account",
    saveFailed: "Couldn't save that change: {0}",
    offline: "Offline. Showing the last tasks fetched.",
    expiresOne: "Sign-in expires in 1 day. Publish the OAuth app (Google Auth Platform > Audience) to stop this.",
    expiresMany: "Sign-in expires in {0} days. Publish the OAuth app (Google Auth Platform > Audience) to stop this.",
    addPlaceholder: "Add a task (a)",
    noTasks: "No tasks. Nice.",
    hints: "space: check · e: edit · x: delete · a: add · h/l: list · c: completed",
    edit: "Edit (e)",
    delete: "Delete (x)",
    deleteConfirm: "Click again to delete",
    completed: "Completed ({0})"
  },

  he: {
    appName: "Google Tasks",
    defaultList: "משימות",
    tooltipSetup: "Google Tasks: לא הוגדר. לחצו לשלבי ההגדרה",
    tooltipSignedOut: "Google Tasks: לא מחובר",
    tooltipExpired: "Google Tasks: פג תוקף ההתחברות",
    tooltipLoading: "Google Tasks: טוען…",
    tooltipCount: "Google Tasks: {0} פתוחות ב־{1}",
    tooltipFailed: " (העדכון האחרון נכשל)",
    justNow: "עכשיו",
    minAgo: "לפני {0} דק׳",
    hoursAgo: "לפני {0} שע׳",
    notConnected: "לא מחובר",
    loading: "טוען…",
    openCount: "{0} פתוחות",
    syncing: "מסנכרן…",
    updated: "עודכן {0}",
    today: "היום",
    tomorrow: "מחר",
    yesterday: "אתמול",
    noResult: "gtasks לא החזיר תשובה. הריצו אותו במסוף כדי לראות למה.",
    unknownError: "שגיאה לא ידועה",
    noConnection: "אין חיבור לרשת",
    prevList: "הרשימה הקודמת ({0})",
    nextList: "הרשימה הבאה ({0})",
    refresh: "רענון (r)",
    openWeb: "פתיחת Google Tasks בדפדפן",
    language: "שפה: {0}",
    languageSystem: "מערכת ({0})",
    setupText: "הגדרה חד־פעמית: ב־Google Cloud Console הפעילו את Google Tasks API, צרו OAuth client מסוג \"Desktop app\" ושמרו את קובץ ה־JSON שלו בנתיב ~/.config/gtasks/client_secret.json. אחר כך התחברו למטה.",
    expiredText: "‏Google ניתקה את ההתחברות. אם זה קורה בערך כל 7 ימים, אפליקציית ה־OAuth עדיין במצב Testing: פרסמו אותה (Google Auth Platform > Audience > Publish app) והתחברו מחדש.",
    signInText: "התחברו לחשבון Google כדי לטעון את המשימות.",
    connect: "חיבור חשבון Google",
    saveFailed: "השינוי לא נשמר: {0}",
    offline: "אין חיבור. מוצגות המשימות האחרונות שנטענו.",
    expiresOne: "ההתחברות תפוג בעוד יום אחד. פרסמו את אפליקציית ה־OAuth ‏(Google Auth Platform > Audience) כדי למנוע זאת.",
    expiresMany: "ההתחברות תפוג בעוד {0} ימים. פרסמו את אפליקציית ה־OAuth ‏(Google Auth Platform > Audience) כדי למנוע זאת.",
    addPlaceholder: "הוספת משימה (a)",
    noTasks: "אין משימות. יפה.",
    hints: "רווח: סימון · e: עריכה · x: מחיקה · a: הוספה · h/l: רשימה · c: הושלמו",
    edit: "עריכה (e)",
    delete: "מחיקה (x)",
    deleteConfirm: "לחצו שוב כדי למחוק",
    completed: "הושלמו ({0})"
  }
}

function languages() {
  return Object.keys(names)
}

function has(lang) {
  return strings.hasOwnProperty(lang)
}

function locale(lang) {
  return locales[lang] || "en_US"
}

function isRtl(lang) {
  return rtl[lang] === true
}

function tr(lang, key, args) {
  var text = (strings[lang] || strings.en)[key]
  if (text === undefined) text = strings.en[key]
  if (text === undefined) return key
  args = args || []
  return text.replace(/\{(\d+)\}/g, function(match, i) {
    return i < args.length ? String(args[i]) : match
  })
}
