The macOS build is now signed with a Developer ID and notarised by Apple. It opens with no
warning and no workaround — no quarantine flag to clear, no trip through Privacy &
Security. The first launch takes a while because macOS verifies the whole bundle once;
every launch after that is immediate.

That also fixes a real bug rather than just removing a dialog. macOS ties a keychain item
to the code signature that wrote it, and an ad-hoc signature is derived from the binary,
so it changed on every build — which is why v0.2.0 asked for saved passwords again after
each update. The signature is stable now, so a password saved today survives future
updates.

Everything still stays on your device. Passwords go to the system credential store, and
the app makes no network calls beyond the databases you connect to and, if you leave it
on, the update check.

## Updating from v0.2.0

You will be asked for saved passwords one last time. The items in your keychain were
written under the old ad-hoc signature and cannot be carried across; re-entering a
password stores it under the new one, and it stays there from now on.

The bundle identifier also changed, from `app.miesql.MieSQL` to `com.mdenizay.miesql`. On
macOS the updater handles that in place. On Windows the installer treats it as a new
install, so remove the old one from Apps & Features if you had v0.2.0.

## Still the same as v0.2.0

This is a packaging release; nothing changed in what the app can do. It supports
**PostgreSQL and SQLite**. **MySQL and MariaDB are not ported yet** — they worked in
[v0.1.0](https://github.com/mdenizay/miesql/releases/tag/v0.1.0), along with dump and
restore, CSV import, the editable grid and the Structure and DDL tabs. If you depend on
any of those, stay on v0.1.0.

## Install

**macOS** — open the `.dmg` and drag MieSQL to Applications. Universal: Apple Silicon and
Intel.

**Windows** — run the `.exe`. The installer is **not** signed, so SmartScreen will report
an unknown publisher; choose **More info → Run anyway**. It installs for the current user
and needs no administrator rights.

**Linux** — take the `.AppImage` (`chmod +x` it first), or the `.deb` or `.rpm`. Saving
passwords needs a Secret Service provider such as gnome-keyring or KWallet; without one
MieSQL says so and lets you enter the password each time instead.

Prefer to build it yourself:

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql && npm install && npm run app:build
```

## Known limitations

- No MySQL or MariaDB yet, and no Redis, MongoDB or SSH tunnelling.
- No dump, restore or CSV import.
- The result grid is read-only; there is no Structure or DDL tab.
- Certificate validation is not implemented. `verify-ca` and `verify-full` are accepted but
  downgraded to Require, and the app tells you so rather than pretending.
- The Windows installer is unsigned.
- Builds are x86_64 on Windows and Linux; macOS is universal.
- The interface is English only.

Progress and the full checklist: https://github.com/mdenizay/miesql/pull/1
