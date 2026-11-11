# Android Security Triage

A consented, click-to-run Windows toolkit for checking a remote Android phone
for known spyware, stalkerware, and backdoor indicators.

Built for a Samsung Galaxy A16, but works with any Android device that supports
ADB wireless debugging. The phone can be on a different network: the connection
goes through Tailscale, and collection is done over ADB. No app is installed on
the phone.

> **Consent required.** Use this only on a phone you own or have explicit
> written permission to examine. A clean result means no known indicators were
> found in the collected data, not proof that the phone is clean.

## Architecture and full guide

- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** - component diagram, data flow, every
  tool, USB/Wi-Fi/Tailscale paths, scan modes, step-by-step runbook,
  troubleshooting and limits.
- **[`READING-THE-RESULTS.txt`](READING-THE-RESULTS.txt)** - how to interpret the
  automatic flags and MVT severity levels.
- **[`reports/2026-11-11-redmi-12-5g.md`](reports/2026-11-11-redmi-12-5g.md)** -
  a redacted real-world example.

```text
Phone --ADB--> Windows toolkit --bugreport--> MVT
                    |--APKs-----------------> APKiD / MobSF
                    |--all------------------> cases\<timestamp>\
```

## Features

- Samsung integrity checks: verified boot state, Knox warranty bit, bootloader
  lock state, security patch level.
- Third-party app inventory with installer source and APK path.
- Sideloaded app detection (`installer=null`).
- Accessibility services and notification listeners - the main stalkerware
  vectors.
- Device administrators, VPN, Private DNS, developer options, ADB state.
- Android users/profiles and registered accounts.
- Running processes, services, and a bounded logcat.
- APK pulling with SHA-256 hashes.
- Automatic `adb bugreport` collection plus MVT known-indicator analysis.
- Optional interactive androidqf deep acquisition.
- Optional MobSF APK scanning through Docker.
- Live phone screen through scrcpy.
- Remote connection over Tailscale, with a local Wi-Fi/USB fallback.
- One-click account switching if the PC is signed in to the wrong Tailscale
  account.

## Requirements

- Windows 10 or Windows 11.
- PowerShell 5.1 or newer (included with Windows).
- Python 3.11+ available as `python` or `py -3`. MVT and APKiD run in a local
  virtual environment; nothing is installed system-wide.
- Tailscale installed on the PC and the phone. Free plan is enough.
- Optional: Docker Desktop for MobSF.
- An Android phone with Developer options and Wireless debugging enabled.

`adb`, `androidqf`, `scrcpy`, `.venv`, MVT, and APKiD are installed locally in
this folder on first run. `tools/` and `.venv/` are intentionally excluded from
Git; they are recreated automatically.

## Quick start

1. Download or clone this repository.
2. Double-click **`START-HERE.bat`**.
3. The first run downloads Android platform-tools, androidqf, and scrcpy, then
   creates `.venv` and installs MVT and APKiD (versions pinned in
   `requirements.txt`). This can take a few minutes.
4. Connect the phone:
   - **1** for remote over Tailscale (recommended for a phone on another
     network), or
   - **2** for same Wi-Fi / USB.
5. Run **2 - FULL scan**.
6. Review the newest folder under `cases\`.

No admin rights and no system PATH changes are required. The launchers add the
local tool folders to PATH for the current session only.

## Remote connection

Tailscale tailnets do not merge automatically. Choose one:

- **Path A - invite:** invite the phone owner's email to your tailnet. The
  phone appears directly in `tailscale status`.
- **Path B - share:** the owner keeps their own tailnet and shares only the
  phone with your Tailscale account. More private; the owner does not see your
  other devices.

Then on the phone:

1. Enable Developer options (tap Build number 7 times).
2. Enable Wireless debugging.
3. Tap "Pair device with pairing code" only when the toolkit asks for it.
4. Read the pairing port and 6-digit code to the operator.
5. After pairing, read the connect port from the main Wireless debugging
   screen.

The toolkit prompts for the pairing port, the pairing code, and then the
connect port. The pairing port and the connect port are different.

### If Wireless debugging and Tailscale conflict

Android only enables Wireless debugging while the phone is on Wi-Fi. If that
Wi-Fi blocks Tailscale (the phone shows "Out of sync"), use ADB over TCP:

1. On a Windows PC, connect the phone by USB and enable USB debugging.
2. Run `adb tcpip 5555` (the `tools\platform-tools` folder in this repo
   works).
3. Unplug USB. The phone can stay on mobile data, so Tailscale stays online.
4. On the operator PC, run `CONNECT-TCP-5555.bat`.
5. Start the scan.

After the scan, reconnect USB and run `adb usb`, or restart the phone, to
close port 5555.

A ready-to-run helper is included as **`ADB-TCPIP-HELPER.zip`**. It contains
ADB and `ENABLE-ADB-TCPIP.bat` / `DISABLE-ADB-TCPIP.bat`, so the USB-side PC
does not need a separate platform-tools download.

Full details:

- **`END-TO-END-GUIDE.md`** - complete operator runbook, including both
  Tailscale paths, pairing, scanning, and cleanup.
- **`FOR-PHONE-OWNER.txt`** - send this to the phone owner; it contains the
  exact phone-side steps.
- **`HOW-TO-USE.txt`** - shorter quick reference.

## Menu

| Option | Action |
|---|---|
| 1 | Connect phone (remote over Tailscale / local Wi-Fi or USB) |
| 2 | FULL scan: collector + ADB bugreport + MVT |
| 3 | Quick scan: collector + APK pull |
| 4 | Deep androidqf acquisition (interactive) |
| 5 | Open last case folder |
| 6 | Open live phone screen (scrcpy) |
| 7 | Start MobSF APK scanner (Docker, optional) |
| 8 | Check / repair tools |
| 9 | Show ADB device list |
| 10 | Tailscale status / remote help |
| 11 | Switch Tailscale account |
| 0 | Exit |

## What gets collected

The collector creates a timestamped case folder:

```text
cases\a16_YYYYMMDD_HHMMSS\
  summary.txt                 parsed flags and device overview
  packages_thirdparty.txt     app list, installer, APK path
  accessibility.txt           enabled accessibility services
  settings_secure.txt         accessibility / notification listeners
  settings_global.txt         VPN, Private DNS, developer options, ADB
  device_policy.txt           active device administrators
  accounts.txt                accounts registered on the device
  processes.txt               running processes
  logcat_tail.txt             last 5000 log lines
  dumpsys_package.txt         full package metadata
  bugreport.zip               ADB bugreport (Full scan)
  mvt_results_bugreport\      MVT JSON findings
  apks\                       pulled sideloaded APKs
  apk_hashes.txt              SHA-256 of pulled APKs
  androidqf\                  only in Deep mode
```

A bugreport can take 5-15 minutes over a remote connection, sometimes longer
when Tailscale relays traffic through DERP.

## Scan modes

- **Quick** - collector and APK pull only. Fastest.
- **Full** - collector, `adb bugreport`, and MVT known-indicator analysis.
  Fully automatic.
- **Deep** - interactive androidqf acquisition, then MVT. androidqf 1.8.3 asks
  questions in the console; answer them. Slower and optional.

## Reading the results

The automatic flags are heuristics, not a malware verdict. `READING-THE-RESULTS.txt`
explains each common flag (sideloaded apps, vendor installers, notification
listeners, multiple profiles, MVT severities) and lists the findings that do
warrant escalation. Read it before acting on `summary.txt`.

Two rules that prevent most false alarms:

- `installer=null` is normal for preinstalled vendor apps.
- `Knox warranty bit` is a Samsung-only field; ignore it on other phones.

## Example report

A real consented scan is published as a redacted summary:

- [`reports/2026-11-11-redmi-12-5g.md`](reports/2026-11-11-redmi-12-5g.md)

It shows the findings and the level of detail a report contains. The case
folder itself (bugreport, APKs, account dump) stays local. Serial numbers,
account identifiers, IP addresses, per-service account counts and the personal
app list are removed before publication.

## Switching Tailscale accounts

If the PC is signed in with an account that is not yours, run
**`SWITCH-TAILSCALE-ACCOUNT.bat`** (or menu option 11). It shows the current
account, signs the PC out after confirmation, and opens the Tailscale login
flow. The toolkit reads the new IP dynamically, so no script changes are
needed.

Signing out invalidates this PC's Tailscale node key. The old tailnet may still
show the PC as an offline device until its owner removes it; only the owner of
that account can delete the device entry.

## Safety and limitations

- Only examine a phone you own or have explicit written consent to examine.
- Do not post pairing ports or codes in a group chat.
- Do not port-forward ADB on the phone's router. Tailscale is the secure path.
- A non-rooted phone cannot be fully imaged. This is a triage snapshot, not a
  forensic image.
- A clean result means no known indicators were found, not proof of
  cleanliness. False negatives and false positives are both possible.
- Keep the case folder secure; it contains personal data.
- If malware is suspected, preserve the case folder before resetting the phone,
  change passwords from a clean device, and enable 2FA.

## Third-party tools

The toolkit downloads and orchestrates open-source tools. They retain their own
licenses and are not vendored in this repository.

- [MVT](https://github.com/mvt-project/mvt) - Mobile Verification Toolkit
- [androidqf](https://github.com/mvt-project/androidqf) - Android Quick
  Forensics
- [scrcpy](https://github.com/Genymobile/scrcpy) - display and control Android
  devices
- [APKiD](https://github.com/rednaga/APKiD) - APK identifier
- [Android platform-tools](https://developer.android.com/tools/releases/platform-tools)
  - adb
- [MobSF](https://github.com/MobSF/Mobile-Security-Framework-MobSF) - optional
  APK scanner
- [Tailscale](https://tailscale.com/) - WireGuard-based remote network

## License

MIT. See `LICENSE`.
