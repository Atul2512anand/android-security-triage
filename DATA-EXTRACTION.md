# Data extraction: WhatsApp, Telegram, Chrome, logs and app data

This guide answers one question honestly: **how much can actually be taken off an
Android phone, and what does it cost in effort, risk and money?**

The short answer:

- On a **locked, non-rooted** Android phone, ADB can copy **shared storage** and
  run each app's **own export** feature. It cannot read `/data/data`.
- The live WhatsApp database, Chrome history/cookies, Telegram databases, SMS
  database, call log and app tokens live in `/data/data`. **No free tool can read
  those over plain ADB.** That is the app sandbox working as designed.
- There are only three ways around it: **root**, a **commercial forensic tool**
  with an exploit, or the **app's own export** (partial, but often enough).

The toolkit can do the first and third. It cannot manufacture the second.

> Use this only on a phone you own or have explicit written permission to
> examine. The exported folder contains personal data. Keep it local, encrypt it
> if it leaves the PC, and delete it when you are done.

---

## 1. What is available at each level

| Data | Without root | With root | Best route |
|---|---|---|---|
| Photos / videos / DCIM | Yes | Yes | `adb pull` |
| Downloads, Documents, Movies | Yes | Yes | `adb pull` |
| WhatsApp media (photos, voice notes, documents) | Yes | Yes | `adb pull` |
| WhatsApp **encrypted** local backups (`.crypt14`) | Yes, but ciphertext | Yes | `adb pull`; decrypt with the key |
| WhatsApp **live** `msgstore.db` / `wa.db` | **No** | Yes | Root, or in-app export |
| WhatsApp messages in readable form | Partial | Yes | In-app "Export chat", or root + SQLite |
| WhatsApp Google Drive backup | Restore to a new phone; 64-digit key | Same, plus the key file | `wa-crypt-tools` needs the `.crypt15` file |
| Telegram media / files in shared storage | Yes | Yes | `adb pull` |
| Telegram **live** `cache4.db` | **No** | Yes | In-app "Export Telegram data", or root |
| Telegram messages / contacts / sessions | Yes | Yes | In-app export (JSON/HTML) |
| Chrome **History** database | **No** | Yes | Google Takeout, or root |
| Chrome **Cookies** | **No** | Maybe | Root + Frida/Keystore; commercial tool |
| Chrome saved passwords | No | Maybe | Google Password Manager; root + OSCrypt |
| SMS / MMS | No (usually) | Yes | SMS exporter app, or root |
| Call log | No (usually) | Yes | Call-log exporter app, or root |
| Contacts | Yes | Yes | Contacts app → export `.vcf` |
| Logs (logcat, bugreport) | Yes | Yes | `adb bugreport`, `adb logcat` |
| Notification history | Partial | Yes | `dumpsys notification`, root DB |
| Wi-Fi passwords | No | Yes | Root (Wi-Fi config XML) |
| Accounts (names/types) | Masked list | Yes | `dumpsys account`, root DB |
| App tokens / session keys | No | Maybe | Root + app context; some are hardware-backed |
| Android Keystore secrets | No | **No** | Non-exportable by design |
| Clipboard | No | Maybe | Root or accessibility service |
| Google location / Photos / activity | No | No | Google Takeout |
| Deleted files / messages | No | Maybe | Free-space carving; often overwritten |

"Maybe" means it depends on the app version, the phone, and whether the data is
protected by the hardware Keystore. Do not promise a clean "yes" for cookies,
passwords or tokens.

---

## 2. Level 1 — no root (start here)

This is safe, reversible, and works on the current phone. Do it **before** any
root attempt, because unlocking the bootloader wipes the phone.

### 2.1 One-click shared-storage export

Run:

```text
EXPORT-DATA.bat
```

or:

```powershell
.\export-data.ps1 -Preset all -WithBugreport
```

It creates `cases\export_<timestamp>\` and can copy:

- `shared\DCIM`, `shared\Pictures`, `shared\Movies`
- `shared\Download`, `shared\Documents`, `shared\Recordings`
- `shared\whatsapp\Media` — WhatsApp photos, video, audio, documents
- `shared\whatsapp\Databases` — the **latest two** encrypted backups
- `shared\telegram\` — Telegram media and files from both possible locations
- `logs\` — logcat, notifications, usage stats, accounts, Wi-Fi, recent tasks,
  package list, accessibility, device policy, settings
- `logs\content\` — an attempt to read SMS, call log and contacts through the
  `content` command (often denied; the error is recorded)
- `manifest.csv` — path, size and SHA-256 for every exported file
- `EXPORT-README.txt` — what was copied, what failed, and what is still missing

Options:

```powershell
# Only WhatsApp media + latest encrypted backups
.\export-data.ps1 -Preset whatsapp

# Only Telegram files
.\export-data.ps1 -Preset telegram

# Only photos and videos
.\export-data.ps1 -Preset media

# Only logs and system state
.\export-data.ps1 -Preset logs

# Preview sizes without copying anything
.\export-data.ps1 -Preset all -ListOnly

# Root mode (only works if the phone is already rooted)
.\export-data.ps1 -Root
```

The tool never prints file contents to the console. It records commands in
`commands.log` and pull output in `pull.log` for chain of custody.

### 2.2 WhatsApp

**Messages, one chat at a time (works now):**

1. Open the chat in WhatsApp.
2. Menu → **More** → **Export chat**.
3. Choose **Without media** (small text file) or **Include media** (ZIP).
4. Save to Downloads / Files, then run `EXPORT-DATA.bat` and include
   Downloads, or pull it directly:
   ```powershell
   .\tools\platform-tools\adb.exe -s <serial> pull /sdcard/Download "<case>\shared\Download"
   ```

The exported `.txt` contains the messages in that chat. It does not contain the
database, contacts, or deleted messages.

**Full account backup:**

1. WhatsApp → **Settings** → **Chats** → **Chat backup** → **Back up to Google
   Drive**.
2. If **End-to-end encrypted backup** is on, WhatsApp shows a **64-digit key**.
   Save it. Without it, the cloud backup cannot be decrypted.
3. The local backups also appear in
   `/sdcard/Android/media/com.whatsapp/WhatsApp/Databases/` as
   `msgstore.db.crypt14`.
4. `EXPORT-DATA.bat` copies the latest two. They are **encrypted**.

**Decrypting a backup:**

- `.crypt14` (local) needs the key file
  `/data/data/com.whatsapp/files/key`. That file is app-private. **Without root
  you cannot read it.** Copying the `.crypt14` is not enough.
- `.crypt15` (Google Drive end-to-end) can be decrypted with the **64-digit
  key**, using [`wa-crypt-tools`](https://github.com/ElDavoo/wa-crypt-tools):
  ```powershell
  .\.venv\Scripts\python.exe -m pip install wa-crypt-tools
  .\.venv\Scripts\wadecrypt.exe "<64-digit-key>" msgstore.db.crypt15 msgstore.db
  ```
  `wadecrypt` accepts a key file or the 64 digits themselves. It also accepts a
  screenshot of the key if the optional OCR dependencies are installed. You
  still need a copy of the `.crypt15` file; the cloud backup is not downloadable
  from the normal Google Drive interface.
- Once decrypted, open `msgstore.db` with
  [DB Browser for SQLite](https://sqlitebrowser.org/). Messages are in the
  `message` table; chats are in `chat`; contacts are in `wa.db`.

**Media** is in shared storage and is copied by `EXPORT-DATA.bat`. It is not
encrypted.

### 2.3 Telegram

Telegram has the best built-in export of the three.

1. Telegram → **Settings** → **Advanced** → **Export Telegram data**.
2. Select what you need: **messages**, **media**, **files**, **contacts**,
   **sessions**, **profile photos**, **stories**, **other data**.
3. Choose **JSON** (machine-readable) or **HTML** (readable in a browser).
4. Set a size limit if the account is large, then export.
5. Save the result to Downloads, then pull it with `EXPORT-DATA.bat`, or pull the
   folder directly.

The export includes message text, sender names, timestamps, media and a list of
active sessions. It does **not** include the live `cache4.db` or the account's
authorization keys.

Telegram media also sits in:

```text
/sdcard/Android/media/org.telegram.messenger/Telegram/
/sdcard/Telegram/                       (older installs)
```

`EXPORT-DATA.bat` copies both if they exist.

### 2.4 Chrome

**History, bookmarks, passwords, autofill:**

1. Go to [Google Takeout](https://takeout.google.com/) on a trusted PC.
2. Deselect everything, then select **Chrome**.
3. Export. The ZIP contains `History.json`, `Bookmarks.html` and related files.
4. Open `History.json` in a text editor, or import it into a spreadsheet.

Chrome's on-device `History` SQLite database is in
`/data/data/com.android.chrome/app_chrome/Default/History` and is **not readable
without root**.

**Cookies:** not in Takeout and not exportable from Chrome Android. They live in
`/data/data/com.android.chrome/app_chrome/Default/Cookies` and the values are
encrypted with a key held by Android Keystore. Even with root, offline
decryption usually fails; a Frida hook inside Chrome or a commercial forensic
tool is needed. Treat "extract all Chrome cookies" as a forensic-lab job, not a
one-click script.

**Recent URLs without root:** `dumpsys activity recents` sometimes contains
recent task URLs. `EXPORT-DATA.bat -Preset logs` saves it as `recents.txt`. It is
metadata, not full history.

### 2.5 SMS, call log and contacts

**Contacts (works now):**

1. Contacts app → **Manage contacts** → **Import/export** → **Export to storage**.
2. Save the `.vcf` to Downloads.
3. Pull it with `EXPORT-DATA.bat`.

**SMS and call log (works with a helper app):**

Android does not let the ADB shell read the SMS or call-log providers on most
builds. The practical no-root route is an exporter app that you install, grant
permission to, export to a file, and then uninstall:

- **SMS Backup & Restore** (SyncTech) exports SMS/MMS to XML.
- **Call Logs Backup & Restore** (SyncTech) exports the call log to XML.
- Any similar exporter that writes to Downloads works. Read its privacy policy
  first; it can read all your messages.

After exporting, pull the XML with `EXPORT-DATA.bat` and keep it in the case
folder. The XML is plain text; treat it as sensitive.

`EXPORT-DATA.bat -Preset logs` also tries `content query` for SMS, call log and
contacts. On most Android 15 phones this returns `Permission Denial`. The tool
records the error instead of failing.

### 2.6 Logs

`EXPORT-DATA.bat -Preset logs` collects:

- `logcat_all.txt` — last 20,000 lines from all buffers
- `notifications.txt` — `dumpsys notification --noredact` (may be redacted by
  the OS)
- `usagestats.txt` — app usage statistics
- `accounts.txt` — account names/types (often masked)
- `wifi.txt` — Wi-Fi state (passwords are not included)
- `recents.txt` — recent tasks, sometimes with URLs
- `device_info.txt`, `packages_thirdparty.txt`, `accessibility.txt`,
  `device_policy.txt`, `settings_secure.txt`, `settings_global.txt`

Add `-WithBugreport` for a full `adb bugreport` ZIP. It takes 5–15 minutes over
a remote connection and contains system logs, tombstones, ANRs and a large
`dumpsys` snapshot.

### 2.7 What no-root mode will never give you

- the live WhatsApp `msgstore.db`;
- the WhatsApp backup key file;
- Chrome `History`, `Cookies`, `Login Data`;
- Telegram `cache4.db` and authorization keys;
- SMS/call-log/contacts SQLite databases (on most builds);
- Wi-Fi passwords, Keystore secrets, app tokens;
- deleted messages or files.

If a free tool claims to do these over plain ADB, it is using an exploit,
quietly requires root, or is fake.

### 2.8 OEM local backup (maybe, proprietary)

Xiaomi/HyperOS has a local backup that runs as a **system service**, so it can
sometimes include app data that ADB cannot read. It is worth trying for
WhatsApp and Chrome before root:

1. Settings → About phone → Backup & reset → **Local backups**.
2. Back up, select the apps, and include app data.
3. The result is under `MIUI/backup/AllBackup/...`; pull it with ADB.

Caveats: the format is proprietary, may be encrypted, may silently exclude
apps, and Telegram often disables Android backup. Treat it as a bonus, not a
reliable route. Test the restore/extract on a spare phone before relying on it.
It does not give you Chrome cookies.

---

## 3. Level 2 — root (the only free way to the live databases)

Root gives the toolkit read access to `/data/data`. It is also the point of no
return for the phone.

### 3.1 What root costs

- **Unlocking the bootloader wipes the phone.** Photos, chats, accounts and app
  data are erased. Export everything you can first (section 2).
- Xiaomi/HyperOS requires **Mi Unlock**, an account bound to the phone, and a
  waiting period (often 7 days, sometimes longer). The exact rules change.
- Rooting trips **Play Integrity**, may break banking apps, Google Wallet, some
  DRM video apps and OTA updates.
- A bad flash can brick the phone. Follow the device-specific guide.
- Root does **not** decrypt hardware-backed Keystore secrets, and it does not
  bring back deleted data that has been overwritten.

If the phone is not yours, do not root it. Use the app exports or a forensic
lab.

### 3.2 What you get after root

With Magisk or KernelSU and a working `su`:

```text
/data/data/com.whatsapp/databases/msgstore.db     messages, chats
/data/data/com.whatsapp/databases/wa.db           contacts
/data/data/com.whatsapp/files/key                 crypt14 backup key
/data/data/com.android.chrome/app_chrome/Default/History
/data/data/com.android.chrome/app_chrome/Default/Network/Cookies    (newer Chrome)
/data/data/com.android.chrome/app_chrome/Default/Cookies            (older Chrome)
/data/data/com.android.chrome/app_chrome/Default/Login Data         (encrypted values)
/data/data/org.telegram.messenger/files/cache4.db              (may be passcode-encrypted)
/data/data/com.android.providers.telephony/databases/mmssms.db
/data/data/com.android.providers.contacts/databases/contacts2.db
/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml
/data/system/users/0/accounts.db
```

WhatsApp's live `msgstore.db` is normally plain SQLite. Telegram's `cache4.db`
may be encrypted if a passcode is set. Chrome cookies and passwords remain
encrypted with Android Keystore; pulling the file is not the same as reading it.

### 3.3 One-click root export

```powershell
.\export-data.ps1 -Root -Yes
```

The script:

1. checks `adb shell su -c id` for `uid=0`;
2. force-stops WhatsApp, Chrome and Telegram so their databases are consistent;
3. tars each package from `/data/data` to `/data/local/tmp`;
4. pulls the tar, deletes it from the phone, extracts it under
   `cases\export_<timestamp>\appdata\`;
5. hashes the tar and writes `appdata_hashes.txt`;
6. prints a note about which files are encrypted.

Default packages:

```text
com.whatsapp
com.android.chrome
org.telegram.messenger
com.android.providers.telephony
com.android.providers.contacts
```

Use `-Packages` to add or replace them:

```powershell
.\export-data.ps1 -Root -Packages com.whatsapp,org.telegram.messenger
```

### 3.4 Manual commands (if you prefer)

```powershell
$adb = ".\tools\platform-tools\adb.exe"
$d = "<serial>"

# Check root
& $adb -s $d shell "su -c id"

# Stop the app, tar its data, pull it
& $adb -s $d shell "su -c 'am force-stop com.whatsapp'"
& $adb -s $d shell "su -c 'tar -cf /data/local/tmp/whatsapp.tar -C /data/data com.whatsapp'"
& $adb -s $d shell "su -c 'chmod 644 /data/local/tmp/whatsapp.tar'"
& $adb -s $d pull /data/local/tmp/whatsapp.tar .\whatsapp.tar
& $adb -s $d shell "su -c 'rm -f /data/local/tmp/whatsapp.tar'"

# Extract on Windows
tar -xf .\whatsapp.tar -C .\appdata
```

Then open `appdata\com.whatsapp\databases\msgstore.db` with DB Browser for
SQLite.

### 3.5 Chrome cookies with root

Pull the `Cookies` database, then expect `encrypted_value` blobs. Android Chrome
uses OSCrypt backed by Android Keystore. Options:

- **Frida** inside Chrome, calling the app's own decryption routine. This is
  advanced, version-specific, and can crash the app.
- A **commercial forensic tool** that supports the device and app version.
- If you only need to stay logged in, use Chrome's own sync/profile restore
  instead of extracting cookies.

Do not advertise "root = cookies in plain text". It is not true on modern
Android.

---

## 4. Level 3 — commercial forensic tools

If you need a **defensible, complete extraction** from a locked phone, the
realistic option is a forensic lab with tools such as:

- Cellebrite UFED / Inseyets
- Oxygen Forensic Detective
- Magnet AXIOM
- MSAB XRY

They use supported exploit chains, preserve chain of custody, and produce a
report that stands up in an investigation. They are not free, not open source,
and support depends on the exact model, Android build and patch level. For a
legal matter, use a lab rather than a home-grown root attempt.

---

## 5. What this project now provides

| File | Purpose |
|---|---|
| `EXPORT-DATA.bat` | Double-click launcher for the export tool |
| `export-data.ps1` | Shared-storage export, logs, manifest, optional root app data |
| `DATA-EXTRACTION.md` | This guide |

The existing triage scan is unchanged. `FULL-SCAN.bat` still looks for spyware
indicators; `EXPORT-DATA.bat` copies the actual content when you need it.

The export tool:

- never installs anything on the phone;
- never prints personal data to the console;
- records every command in `commands.log`;
- hashes every exported file in `manifest.csv`;
- refuses to run without a consent confirmation unless `-Yes` is passed;
- keeps everything under `cases\`, which is gitignored.

Root mode is the only part that writes to the phone, and only to
`/data/local/tmp` for the temporary tar, which it deletes immediately after the
pull.

---

## 6. Legal and practical checklist

1. **Consent.** The owner must understand that you will copy messages, photos,
   contacts and account metadata. Get it in writing if this is not your phone.
2. **Back up first.** If root is planned, copy shared storage and run the app
   exports before unlocking the bootloader.
3. **Keep the case folder local.** `cases\` is gitignored. Do not put it in a
   public repo, chat or cloud folder without encryption.
4. **OneDrive.** This repo lives under OneDrive; OneDrive may sync `cases\`.
   Pause sync or move the case folder if that matters.
5. **Retention.** Decide how long to keep the data and delete it securely when
   done.
6. **Chain of custody.** Keep `commands.log`, `manifest.csv` and the original
   exports together. Do not edit the originals; work on copies.
7. **No surprises.** Tell the owner before force-stopping apps or rebooting.
8. **Cloud data is separate.** Google Takeout, WhatsApp Drive backups and
   Telegram cloud exports need the account credentials; the phone alone is not
   enough.
