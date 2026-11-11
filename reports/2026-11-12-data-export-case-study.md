# Case study: extracting personal data from a non-rooted Android phone

**Date:** 2026-11-12  
**Device:** Redmi 12 5G (`23076RN4BI`), Android 15, HyperOS, security patch 2026-10-01  
**Scope:** consented export of personal data over ADB, without root  
**Result:** about 28,500 files, 13.4 GiB of exported content, and no live app databases

---

## 1. Objective

The triage scan answered "is there anything suspicious on this phone?" This
follow-up answered a different question: "how much of the actual content can be
taken off the phone, and what is still locked away?"

The owner wanted WhatsApp data, Chrome history and cookies, Telegram files, SMS,
call logs, photos, and logs. The phone was locked, non-rooted, and running
Android 15 with apps targeting API 36.

## 2. Method

- Local `platform-tools` ADB over USB.
- `export-data.ps1` from this repository, with the `all` preset.
- Shared-storage copy for photos, downloads, WhatsApp media and Telegram files.
- `content query` for SMS, call log and contacts.
- `dumpsys`, `logcat` and settings snapshots for logs and system state.
- SHA-256 manifest for every exported file.
- No root, no app installs, no changes to app data.

The export is deliberately separate from the triage scan: scanning is read-only
and small, exporting copies personal content.

## 3. What was recovered

| Category | Approx. files | Approx. size | Status |
|---|---:|---:|---|
| WhatsApp media | 24,200 | 5.3 GiB | Complete; file count matches the phone |
| WhatsApp encrypted backups | 2 | 0.5 GiB | `.crypt14` ciphertext, not readable without the key |
| DCIM photos and videos | 810 | 5.1 GiB | Complete |
| Pictures and screenshots | 3,200 | 0.3 GiB | Complete |
| Movies | 200 | 0.05 GiB | Complete |
| Downloads | 90 | 0.25 GiB | Complete |
| Logs and system state | 12 | <0.1 GiB | Complete |
| SMS content query | several thousand rows | <0.1 GiB | Readable on this build |
| Call log | 0 | 0 | Permission denied |
| Contacts | 0 | 0 | Permission denied |
| Telegram shared storage | 0 | 0 | Empty; in-app export is required |
| Preservation tar | 1 | 1.8 GiB | Duplicate of WhatsApp Documents |
| Reports, manifest, scripts | 9 | <0.1 GiB | Case metadata |
| **Total** | **~28,500** | **~13.4 GiB** | |

The total includes a 1.8 GiB tar kept as the original container for the
WhatsApp Documents folder. The unique content is therefore about 11.6 GiB.

## 4. Technical findings

### 4.1 Windows cannot store every Android filename

One PDF in WhatsApp Documents had a line break in its Android filename. Linux
allows that; Windows does not. `adb pull` stopped the entire WhatsApp media copy
with:

```text
adb: error: cannot create '...': Not a directory
```

The workaround was:

1. copy the other WhatsApp folders individually;
2. stream the affected folder through `adb exec-out tar`;
3. extract the tar with a Python script that replaces characters Windows cannot
   store;
4. keep a mapping from original to sanitized names.

In this case 629 Documents files were extracted, and 325 names were sanitized.
The original tar and name map were kept with the case until the content was
deleted.

This is a Windows limitation, not an Android permission failure. The same pull
from Linux or macOS would have kept the original name.

### 4.2 `content query` is inconsistent

On this phone the ADB shell could read the SMS provider and returned several
thousand rows. The call-log and contacts providers returned permission errors.
That behaviour varies by OEM and Android build. A tool must record the error and
continue, not treat it as a fatal failure.

### 4.3 `adb backup` is not a way around the sandbox

`adb backup` no longer includes app data for apps targeting API 31 or newer. Both
WhatsApp and Chrome on this phone target API 36. `run-as` also refused because
the apps are not debuggable.

### 4.4 Root is not a universal decryptor

Root can expose `/data/data` and therefore the live WhatsApp database, Chrome
history, Telegram cache and the SMS/contacts databases. It does not make Chrome
cookies or saved passwords plaintext: those values are protected by Android
Keystore/OSCrypt. Extracting them needs a Frida hook inside Chrome or a
commercial forensic tool.

Rooting this phone would also unlock the bootloader and wipe it, so the no-root
exports had to happen first.

### 4.5 Telegram shared storage can be empty

The Telegram media directory existed but contained no files. Telegram keeps most
content in its app-private cache. The practical no-root route is the in-app
**Settings → Advanced → Export Telegram data** flow, which can write JSON/HTML
and media to shared storage.

## 5. What no-root mode could not obtain

- the live WhatsApp `msgstore.db`, `wa.db` and the `.crypt14` key file;
- Chrome `History`, `Cookies` and `Login Data`;
- the live Telegram `cache4.db`;
- the call-log and contacts SQLite databases;
- Wi-Fi passwords, app tokens and Keystore secrets;
- deleted messages or files.

These need one of:

1. the app's own export feature (partial but practical);
2. root (wipes the phone, and cookies may still be encrypted);
3. a commercial forensic tool with a supported exploit and chain of custody.

## 6. Lessons for the toolkit

- Keep scanning and content export as separate workflows.
- Hash every exported file and write a report of what failed.
- Treat unrepresentable Windows filenames as a known failure mode and fall back
  to tar plus sanitized extraction.
- Do not promise live app databases from a non-rooted phone.
- Do not put case data in Git, and think twice before putting it in a
  cloud-synced folder.
- Run the no-root exports before any bootloader unlock or root attempt.

## 7. Retention

The full 13.4 GiB content folder was deleted after this summary was written.
Only the aggregate category summary and the SHA-256 of the deleted manifest were
kept. The manifest hash is:

```text
9C2EDC3A0EE155A0A3A4B7D27F07292111D690D5E7F25D03456B90F18B7B4FCA
```

No personal content, account identifiers, serial numbers or case data are
included in this public report.
