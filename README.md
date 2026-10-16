# Google Tasks for Omarchy (`emanuel.gtasks`)

An Omarchy bar widget for [Google Tasks](https://tasks.google.com/). The icon shows how
many tasks are open. The panel lets you add tasks, check them off, reopen them,
delete them, and switch between lists. Changes sync to Google right away and
show up in the Google Tasks app on your phone.

Everything goes through `gtasks`, a small Python CLI included here that uses
only the standard library. It also works on its own in a terminal.

## Install

```sh
omarchy plugin add https://github.com/Emanuel4100/omarchy-google-tasks.git
omarchy plugin enable emanuel.gtasks
ln -s ~/.config/omarchy/plugins/emanuel.gtasks/gtasks ~/.local/bin/gtasks
```

Optional quick-add shortcut, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "Google Tasks", "omarchy-shell emanuel.gtasks compose")
```

## Setup

The plugin has no server and no shared Google app. You sign in through an
OAuth client that you create yourself, so your tasks only ever go between your
computer and Google. Creating the client is a one-time setup in Google Cloud
(about 5 minutes, free):

1. Create a project at https://console.cloud.google.com/projectcreate
2. Enable the **Google Tasks API**:
   https://console.cloud.google.com/apis/library/tasks.googleapis.com
3. **Google Auth Platform → Branding**. Fill in:
   - App name (anything, e.g. `omarchy-tasks`) and your email
   - Application home page: `https://github.com/Emanuel4100/omarchy-google-tasks`
   - Application privacy policy link:
     `https://github.com/Emanuel4100/omarchy-google-tasks/blob/main/PRIVACY.md`
   - Authorized domain: `github.com`

   Then go to **Audience**, choose *External*, and press **Publish app**. Google
   requires the home page and privacy policy before it allows publishing. Apps
   left in *Testing* get their sign-in ended by Google every 7 days. Publishing
   needs no Google review for personal use (fewer than 100 users). It doesn't
   make the app public, because it only works with your own client ID. If
   Google won't accept the links, add yourself under **Audience → Test users**
   instead, and reconnect from the panel once a week. If you forget, the panel
   shows "Sign-in expires in N days" when Google reports a time limit.
4. **Google Auth Platform → Clients → Create client**, type **Desktop app**.
   Download the JSON from the dialog that appears right away. Google shows
   the secret only once.
5. Sign in:

   ```bash
   gtasks auth --client-secret ~/Downloads/client_secret_XXXX.json
   ```

   Google warns that the app isn't verified, because you created it yourself.
   Choose *Advanced → Go to (app name)*. If a checkbox for your tasks appears,
   tick it, then press *Continue*.

The client JSON is copied to `~/.config/gtasks/client_secret.json`, and the
sign-in token is stored in `~/.local/state/gtasks/token.json` (mode 0600).
Don't sync or commit either file. `gtasks logout` revokes the token. See
[PRIVACY.md](PRIVACY.md) for what the plugin accesses.

## Using the widget

| Action | Effect |
| --- | --- |
| Click | Open the panel |
| `SUPER + SHIFT + T` / middle-click | Open the panel with the cursor in "Add a task"; again to close |
| Right-click | Refresh |

In the panel:

| Key | Effect |
| --- | --- |
| `a` / `i` / `o` / `/` | Add a task (Enter saves, Esc leaves the field) |
| `j` / `k` / arrows | Move between tasks |
| Space / Enter | Check off or reopen the selected task |
| `x` twice | Delete the selected task |
| `h` / `l` | Previous or next list |
| `c` | Show or hide completed tasks |
| `r` | Refresh |
| Esc | Close |

`omarchy-shell emanuel.gtasks compose` (the shortcut from Install) opens the
panel ready to add a task, or closes it when it is already open. The
`open`, `close`, `toggle` and `refresh` methods also work.

Settings (`omarchy bar set emanuel.gtasks <key> <value>`): `showCount`
(default `true`) and `refreshMinutes` (default `5`).

## CLI

```text
gtasks show [--all]                      tasks in the current list
gtasks add Buy milk --due 2026-10-20     add a task
gtasks done|undo|delete TASK_ID          change a task (ids are shown by `show`)
gtasks lists / gtasks use Work           list task lists / pick the default
gtasks --json snapshot                   the JSON the widget renders
```

Not supported yet: editing a task's title, notes, or due date, and reordering.
Use the browser button in the panel for those.
