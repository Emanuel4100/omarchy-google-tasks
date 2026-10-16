# Privacy policy: Google Tasks for Omarchy

Last updated: 2026-10-16

Google Tasks for Omarchy (the `emanuel.gtasks` plugin and its `gtasks` command)
is open-source software that runs entirely on your own computer. There is no
server behind it. Each person who installs it signs in through a Google OAuth
client that they created themselves in their own Google Cloud project.

## What it accesses

With your permission (the Google scope `https://www.googleapis.com/auth/tasks`),
it reads your task lists and tasks, and creates, completes, reopens, and
deletes tasks when you ask it to. It refreshes your tasks every few minutes
so that the bar stays up to date.

## Where your data goes

- It connects only to Google: `accounts.google.com` and `oauth2.googleapis.com`
  to sign in, and `tasks.googleapis.com` for your tasks.
- Your tasks are shown on your screen and are not written to disk.
- Your sign-in token is stored on your computer in
  `~/.local/state/gtasks/token.json`, readable only by your user account.
  Your OAuth client file is stored in `~/.config/gtasks/`.
- Nothing is sent to the author or to anyone else. There are no analytics,
  no tracking, and no third-party services.

The use of information received from Google APIs complies with the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Removing access

Run `gtasks logout` to revoke the token and delete it from your computer. You
can also remove the app at https://myaccount.google.com/permissions.
Uninstalling the plugin (`omarchy plugin remove emanuel.gtasks`) removes the
software. Delete `~/.config/gtasks/` and `~/.local/state/gtasks/` to remove
everything else.

## Contact

Questions or problems:
https://github.com/Emanuel4100/omarchy-google-tasks/issues
