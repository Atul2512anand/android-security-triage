# End-to-End Guide: Remote Samsung A16 Scan

This is the full operator runbook: your PC, your tailnet, the phone owner's
side, the connection, the scan, and the cleanup. Follow it top to bottom.

Everything here is consented. The owner must know what will be read and must
agree before you connect.

---

## 0. The 30-second version

1. You already have Tailscale on this PC. Run `tailscale status` to see your
   current IP and account.
2. The owner installs Tailscale on the phone. Either:
   - **Path A:** you invite their email into your tailnet, or
   - **Path B:** they keep their own tailnet and share only the phone with you.
3. The owner turns on **Wireless debugging** and reads you **two ports + one code**.
4. You double-click `REMOTE-SETUP.bat`, pair, connect.
5. You double-click `START-HERE.bat` -> `2` (FULL scan).
6. You review `cases\a16_*\summary.txt` and the MVT results.

Time: about 10 minutes to connect, 5-15 minutes for the full scan.

---

## 1. Understand the two tailnets

A Tailscale **tailnet** is a private encrypted network. Two separate tailnets
do **not** automatically see each other. There are exactly two practical ways
to make your PC reach the phone.

### Path A - the owner joins YOUR tailnet

```
YOUR TAILNET
  +-- your PC        100.x.y.z
  +-- owner's phone  100.x.x.x
```

- One tailnet, fewest steps.
- You invite the owner's email. They sign in with that exact email.
- The phone appears directly in your `tailscale status`.
- Privacy note: with Tailscale's default ACL, every user in a tailnet can see
  and reach every device. The owner would be able to see your other devices
  (ZSECURE, laptop, etc.). Only use this with someone you trust, or tighten
  the ACL first. For a cleaner privacy boundary use Path B.

### Path B - the owner keeps THEIR tailnet and shares only the phone

```
YOUR TAILNET                         OWNER'S TAILNET
  +-- your PC  100.x.y.z  <--share--  phone  100.x.x.x
```

- Two separate tailnets. Only the phone is shared with your account.
- Sharing is available on all Tailscale plans, including free.
- The owner needs their own free Tailscale account. If they already use
  Tailscale, this is the natural choice.
- You must be an Owner, Admin, or IT admin of your own tailnet to accept the
  share (you are).
- A shared machine is **quarantined by default**: it can receive connections
  from your tailnet but cannot start connections into it. That is exactly what
  ADB needs - your PC connects to the phone - and it is safer for both sides.
- The shared phone is visible only to your user account, not to every device
  in your tailnet.
- More private: the owner does not join your tailnet and does not see your
  other devices.

### Which should you choose?

| Situation | Use |
|---|---|
| Owner is trusted, wants the fewest steps, no Tailscale account yet | **Path A** |
| Owner already has Tailscale, or privacy between tailnets matters | **Path B** |
| Owner is non-technical and you are on a call | **Path A** |
| You do not want the owner to see your other devices | **Path B** |

---

## 2. Before you start

### On your side

- Windows PC with this folder.
- Tailscale installed, running and signed in. Run `tailscale status` to see
  the account and `tailscale ip -4` to see the PC's current address. The
  scripts read both automatically, so they keep working if you switch
  accounts.
- The toolkit installed in this folder (already true).
- A call or chat open with the owner.
- The owner's email address (for the Path A invite).
- Your own Tailscale email address ready to give the owner (for the Path B share).

### On the owner's side

- Samsung A16, charged above 50 percent.
- Play Store access.
- The phone's PIN (needed to unlock Developer options).
- Ability to keep the phone unlocked and on the charger for 15-30 minutes.
- No other VPN active (Samsung Secure Wi-Fi, work VPN, etc.).

### Consent

Confirm in writing if possible: the owner agrees to a security check, knows
that app lists, settings, accounts, logs, and a bugreport will be collected,
and knows they can stop at any time.

---

## 3. Your PC: preflight check

Do this before calling the owner.

1. Double-click `SETUP-TOOLS.bat`.
   You should see:

   ```
   adb ........ OK    androidqf ... OK    scrcpy ... OK
   MVT ........ OK    APKiD ....... OK
   tailscale .. OK    python ...... OK
   phone ...... not connected
   ```

2. Optional PowerShell check (open PowerShell in this folder):

   ```powershell
   tailscale status
   tailscale ip -4
   .\tools\platform-tools\adb.exe version
   ```

   Expected: your PC's `100.x.y.z` address, adb version 37.0.1.

3. Confirm which email is signed in to Tailscale. This is the email you give
   the owner in Path B, and the account that sends the invite in Path A.

4. Decide Path A or Path B and tell the owner which one you are doing.

---

## 3.5. If the PC is signed in with an account that is not yours

Tailscale ties this PC to one account at a time. If `tailscale status` shows an
account that is not yours, switch it before doing anything else.

### Step 1 - create or locate your own Tailscale account

If you do not have one, open this in a **private/incognito** browser window:

<https://login.tailscale.com/start>

Sign up with your own Google, Microsoft, or email account. That creates your
own free tailnet. You will be its owner/admin, so you can invite the phone
owner or accept a share.

### Step 2 - sign this PC out of the old account

Double-click **`SWITCH-TAILSCALE-ACCOUNT.bat`**, or use
`START-HERE.bat` -> `11`.

The script:

1. Shows the account currently signed in.
2. Asks you to type `YES`.
3. Runs `tailscale logout`.
4. Opens the Tailscale login flow.
5. Shows the new account and new Tailscale IP.

Sign in with **your** account. If the browser auto-selects the old Google
account, click **Use another account**, or paste the login URL into the
private window.

### Step 3 - verify

```powershell
tailscale status
tailscale ip -4
```

The first line should show your account, not the old one. The PC's `100.x`
address will change. That is fine: the toolkit reads the IP dynamically via
`tailscale ip -4`, so no script edits are needed.

### Step 4 - remove the old account's access

- Running `tailscale logout` invalidates this PC's node key. The old account
  can no longer use this PC through Tailscale.
- The old tailnet may still list this PC as an **offline** device until its
  owner deletes it. Only the owner of that account can remove it from
  <https://login.tailscale.com/admin/machines>.
- If you control the old account, sign in there, find this PC by name, and
  remove it.
- If you do not control it, ask the old account owner to remove the device.
  Signing out is enough to stop this PC from using that tailnet.

### Optional - fully purge the old local state

If you want no trace of the old Tailscale node on this PC:

1. Uninstall Tailscale: Settings > Apps > Installed apps > Tailscale >
   Uninstall.
2. Delete leftover state folders (optional, requires admin):
   `C:\ProgramData\Tailscale` and `%LOCALAPPDATA%\Tailscale`.
3. Reinstall from <https://tailscale.com/download/windows>.
4. Sign in with your own account.

Do not delete these folders while you still need the current Tailscale
connection; do it only as part of a clean reinstall.

---

## 4. Path A: invite the owner into your tailnet

### A1. You send the invite

1. Open <https://login.tailscale.com/admin/users>.
2. Click **Invite user** (or **Invite external user**).
3. Enter the owner's email address exactly.
4. Send the invite.
5. If the console gives you a copyable invite link, send that link to the
   owner over WhatsApp/email. Otherwise the email is the link.
6. Tell the owner: "Use exactly this email when Tailscale asks you to sign in."

### A2. Owner accepts and installs

The owner does this on the phone:

1. Open the invite email or the link you sent.
2. If Tailscale is not installed, install it from the Play Store:
   <https://play.google.com/store/apps/details?id=com.tailscale.ipn>
3. Open the invite link again, or open Tailscale and sign in with the **exact
   email you invited** (Google, Microsoft, or email sign-in, whichever that
   address uses).
4. If Tailscale asks which tailnet to join, choose **your** tailnet (it is
   named after your account, not "Personal").
5. Tap the connect button. Android asks to allow a VPN connection - tap **OK**.
6. Confirm Tailscale says **Connected** and shows an address like
   `100.x.y.z`.
7. Keep Tailscale running.

Tell the owner to also do this on Samsung:

- Settings > Apps > Tailscale > Battery > **Unrestricted**.
- Settings > Battery > Background usage limits > make sure Tailscale is not in
  "Sleeping apps" or "Deep sleeping apps".
- If Samsung Secure Wi-Fi or any other VPN is on, turn it off. Android allows
  only one VPN at a time.

### A3. You verify

1. On the PC, open `START-HERE.bat` -> `10` (Tailscale status).
2. Or run `tailscale status` in PowerShell.
3. You should see an `android` peer, online, with a `100.x.x.x` address.
4. If it is there, continue to section 6 (common phone setup).

---

## 5. Path B: owner's own tailnet, share only the phone

Use this when the owner already has Tailscale, or when you do not want them in
your tailnet.

### B1. Owner creates or uses their own Tailscale

The owner does this on the phone:

1. Install Tailscale from the Play Store:
   <https://play.google.com/store/apps/details?id=com.tailscale.ipn>
2. Sign in with their own Google/Microsoft/email account.
3. If Tailscale offers to create a tailnet, accept the default free personal
   tailnet.
4. Tap connect. Android asks to allow a VPN connection - tap **OK**.
5. Confirm Tailscale says **Connected** and shows a `100.x.y.z` address.
6. Set battery to **Unrestricted** (Settings > Apps > Tailscale > Battery).
7. Turn off any other VPN.

### B2. Owner shares only the phone

The owner does this on the phone browser (Chrome/Samsung Internet):

1. Open <https://login.tailscale.com/admin/machines>.
2. Sign in with the same Tailscale account if asked.
3. Find **this phone** in the machine list. It should show as Android and
   online. If there are several devices, match the `100.x.y.z` address shown in
   the Tailscale app.
4. Tap the **...** menu next to the phone (or the **Share** button).
5. Choose **Share**.
6. Enter **your** email address (the operator's Tailscale email).
7. Confirm/send the share. The link is single-use and expires after 30 days.
8. Keep Tailscale connected.

Important: share only the phone. Do not share the whole tailnet and do not
share other devices. If the owner is on a company/work tailnet and does not
have permission to share machines, use Path A instead.

### B3. You accept the share

1. Check your email for a message from Tailscale saying the owner shared a
   device with you.
2. Click **Accept** / **View device**.
3. If there is no email, open
   <https://login.tailscale.com/admin/machines> and look for a pending share
   banner or a "Shared with you" section.
4. In PowerShell, run `tailscale status`. The phone should now appear as an
   `android` peer with a `100.x.x.x` address.
5. Optional reachability test:

   ```powershell
   tailscale ping -c 3 100.x.y.z
   ```

   A reply means your PC can reach the phone over Tailscale.

### B4. If the share does not show up

- Confirm the owner entered your exact Tailscale email.
- Confirm the owner accepted any confirmation screen.
- Confirm the phone is online in the owner's Tailscale app.
- Sharing respects the access control policies of BOTH tailnets. If the
  owner's tailnet or yours has a restrictive ACL, the phone may be visible but
  unreachable. The default policy allows all, so this is usually only an issue
  on a managed/work tailnet.
- If it still fails, switch to Path A (invite the owner into your tailnet).
  Device sharing is convenient, but a same-tailnet invite is the most
  reliable path for ADB.

---

## 6. Common phone setup (both paths)

Do this on the call, after the phone is online in Tailscale. The owner performs
these steps; you guide them.

1. **Settings > About phone > Software information**.
2. Tap **Build number** seven times.
3. Enter the phone's PIN/pattern when asked.
4. Go back to **Settings > Developer options**.
5. Turn on **Wireless debugging**.
6. If Android asks **"Allow wireless debugging on this network?"**, tap
   **Allow**.
7. **Wait for the operator's cue** before tapping **Pair device with pairing
   code**. The popup and code expire quickly; generate them only when the
   operator is ready at the pairing prompt.
8. When the operator says go, tap **Pair device with pairing code**.
9. A popup appears showing:
   - an IP address and **port** (the pairing port),
   - a **6-digit pairing code**.
10. Keep that popup open. Read **only the port and the code** to the operator.
    The IP is not needed; the script already knows the phone's Tailscale IP.
11. After the operator says pairing succeeded, close the popup.
12. The main **Wireless debugging** screen now shows **IP address & Port**.
    The owner reads **only that port** to the operator. This is the connect
    port and it is different from the pairing port.
13. When Android shows **"Allow USB debugging?"** or **"Allow wireless
    debugging?"**, the owner taps **Allow** (and **Always allow from this
    computer** if offered).
14. Optional but recommended: Developer options > **Stay awake** ON.
15. Keep the phone unlocked, on the charger, Tailscale ON, and Wireless
    debugging ON until the operator says the scan is finished.

Rules for the owner:

- Do not read the pairing code into a group chat or post it anywhere.
- Do not reboot the phone during the scan.
- Do not toggle Wireless debugging off during the scan; the ports change.
- If the pairing code expires, tap "Pair device with pairing code" again and
  read the new port/code.
- If the screen locks, unlock it. Some phones pause ADB authorization prompts
  while locked.

---

## 7. You connect the phone

1. Double-click `REMOTE-SETUP.bat`.
   (Equivalent: `START-HERE.bat` -> `1` -> `1` remote.)
2. The script prints:
   - your Tailscale IP (the script prints it),
   - the owner's checklist,
   - the Android devices it can see in the tailnet.
3. If no Android device is listed:
   - wait a few seconds and press Enter to refresh,
   - confirm Tailscale on the phone says Connected,
   - confirm the share was accepted (Path B) or the invite was accepted with
     the right email (Path A).
   - If still no Android peer, the script falls back to listing all online
     peers. Pick the phone by name or IP.
4. Select the phone by number.
5. The script tests Tailscale reachability with `tailscale ping`. If it fails,
   it asks `Try ADB anyway? (y/N)`. Answer `n` and fix Tailscale first, unless
   you specifically want to test the ADB path.
6. When you see the pairing prompt, tell the owner: "Now tap Pair device with
   pairing code." Then enter the **pairing port** from the popup and press
   Enter.
7. When adb prints `Enter pairing code:`, type the **6-digit code**. Press
   Enter. (The code may not echo on screen.)
8. Expected: `Successfully paired to 100.x.y.z:PORT`.
9. When prompted `CONNECT PORT (or full IP:PORT - only the port is used)`:
   type the **connect port** from the main Wireless debugging screen.
10. Expected: `connected to 100.x.y.z:PORT`.
11. The script then checks `adb devices` for up to 30 seconds. If the phone
    shows `unauthorized`, ask the owner to tap **Allow** on the phone.
12. If it still fails, check `START-HERE.bat` -> `9` (ADB device list).

Under the hood, these are the exact commands:

```powershell
.\tools\platform-tools\adb.exe pair 100.x.y.z:PAIRING_PORT
.\tools\platform-tools\adb.exe connect 100.x.y.z:CONNECT_PORT
.\tools\platform-tools\adb.exe devices -l
```

Two different ports. Pairing uses the popup port; connecting uses the main
screen port. Both change if Wireless debugging is toggled or the phone reboots.

---

## 8. Run the scan

1. Double-click `START-HERE.bat`.
2. Choose `2` - **FULL scan (collector + bugreport + MVT)**.
3. If the phone is not connected, the script offers the connection flow again.
4. The scan runs in this order:
   - **Collector**: integrity properties, package inventory, installers,
     accessibility services, notification listeners, device admins, VPN,
     Private DNS, developer options, accounts, processes, logcat, APK pull.
   - **ADB bugreport**: 5-15 minutes over a remote connection. The phone may
     show a notification; do not cancel it.
   - **MVT**: downloads the latest indicators and runs `check-bugreport`.
5. Keep the phone unlocked and charging. Keep Tailscale connected. Do not
   close the PowerShell window.
6. When it finishes, `summary.txt` opens automatically.

Optional deeper acquisition:

- `START-HERE.bat` -> `4` - **Deep androidqf acquisition (interactive)**.
- androidqf 1.8.3 asks questions in the console (backup, APK download,
  intrusion logs). Answer them. This is slower and not needed for the first
  pass; the full scan already produces a bugreport + MVT result.

If the connection drops mid-scan:

1. Re-run `REMOTE-SETUP.bat` (the ports may have changed).
2. Re-run the scan. Case folders are timestamped, so nothing is overwritten.

---

## 9. Review the results

Open the newest folder under `cases\a16_*`.

| File / folder | What to look at |
|---|---|
| `summary.txt` | Automatic flags and device overview. Read this first. |
| `packages_thirdparty.txt` | Every non-system app, its installer, APK path. `installer=null` means sideloaded. |
| `accessibility.txt` | Enabled accessibility services - the main stalkerware vector. |
| `settings_secure.txt` | Accessibility and notification-listener settings. |
| `device_policy.txt` | Active device administrators. |
| `settings_global.txt` | VPN, Private DNS, developer options, ADB state. |
| `accounts.txt` | Accounts registered on the phone. |
| `processes.txt` | Running processes. |
| `logcat_tail.txt` | Last 5000 log lines. |
| `dumpsys_package.txt` | Full package metadata and install times. |
| `bugreport.zip` | The raw Android bugreport. |
| `mvt_results_bugreport\` | MVT JSON findings. Look for `detected` / matched indicators. |
| `mvt_bugreport.log` | MVT console summary. |
| `apk_hashes.txt` | SHA-256 hashes of pulled sideloaded APKs. |
| `apks\` | The pulled APKs themselves. |
| `androidqf\` | Only if you ran the deep mode. |

How to triage:

1. Read every automatic flag in `summary.txt`.
2. Check the accessibility list. A service you do not recognize, especially one
   with a generic name or no launcher icon, is the highest-priority lead.
3. Check installer sources. Apps installed by `null` / `com.android.packageinstaller`
   with no Play Store history deserve a look.
4. Check device admins. "Find My Mobile" is normal; an unknown admin is not.
5. Check VPN / Private DNS. An unknown VPN or DNS can redirect traffic.
6. For any suspicious APK:
   - run `apkid <file.apk>` in the local venv,
   - or upload the SHA-256 to VirusTotal,
   - or scan the file in MobSF (`START-HERE.bat` -> `7`, needs Docker).
7. Check `mvt_results_bugreport\` for matched known indicators.

Important wording: a clean result means **no known indicators were found**,
not proof that the phone is clean. A non-rooted phone cannot be fully imaged.

---

## 10. Disconnect and revoke access

Do this when the scan is finished.

### Phone

1. Turn off **Wireless debugging** (or at least toggle it off after the scan).
2. Turn off **Tailscale**.
3. Optional: uninstall Tailscale if the owner does not want it.

### Your PC

1. Disconnect ADB:

   ```powershell
   .\tools\platform-tools\adb.exe disconnect
   ```

2. Close scrcpy/MobSF if open.

### Path A cleanup

1. Open <https://login.tailscale.com/admin/users>.
2. Find the owner's account.
3. Remove the user from your tailnet (or ask them to leave).
4. Their phone disappears from `tailscale status`.

### Path B cleanup

1. The owner opens <https://login.tailscale.com/admin/machines>.
2. Finds the phone -> **...** -> **Share**.
3. Opens the menu in the Share dialog -> **Revoke invite**.
4. The phone disappears from your `tailscale status`.

### Case data

- Keep the case folder if this may become a legal or HR case.
- If not, delete it after you have written your summary.
- If anything malicious is found, change passwords from a clean device,
  enable 2FA, then factory reset and set up as new.

---

## 11. Troubleshooting

### The phone never appears in `tailscale status`

| Check | Fix |
|---|---|
| Tailscale on the phone says Connected | Open the app, tap connect, allow the VPN prompt |
| Owner signed into the wrong account | Sign out, sign in with the exact invited email (Path A) or the account that shared the phone (Path B) |
| Share not accepted | Open the email link, or the admin console share banner (Path B) |
| Samsung battery saver killed Tailscale | Settings > Apps > Tailscale > Battery > Unrestricted; remove from Sleeping apps |
| Another VPN is active | Turn off Secure Wi-Fi / work VPN; Android allows one VPN |
| Phone is offline in the list | Unlock the phone, open Tailscale, wait for Connected |
| Owner is in a different tailnet | Path A invite, or Path B share; two tailnets do not merge automatically |

### `tailscale status` shows the phone, but ADB cannot reach it

1. Run `tailscale ping -c 3 100.x.y.z`. If this fails, the tailnet path is the
   problem, not ADB.
2. For Path B, confirm the share is accepted. Shared machines are quarantined
   (the phone can receive your connections but cannot start its own into your
   tailnet), which is fine for ADB. If ping still fails, check the ACL policy
   of the owner's tailnet, or switch to Path A.
3. Confirm Wireless debugging is still ON and the phone is unlocked.
4. Confirm you are using the phone's Tailscale IP, not its Wi-Fi IP.

### `adb pair` fails

| Symptom | Cause | Fix |
|---|---|---|
| `failed to connect` | Wrong port, or popup closed | Re-open "Pair device with pairing code", use the new port |
| `Wrong pairing code` | Code expired or mistyped | Generate a new code and retry immediately |
| `connection refused` | Wireless debugging off, or VPN off | Toggle Wireless debugging, confirm Tailscale Connected |
| Timeout | Tailscale relay is slow, or phone asleep | Unlock phone, keep Tailscale open, retry |

### `adb connect` fails

- The connect port is different from the pairing port. Re-read the main
  Wireless debugging screen.
- Toggling Wireless debugging or rebooting changes the port.
- If it says `offline`, run `adb disconnect`, toggle Wireless debugging, then
  reconnect with the new port.
- If it says `unauthorized`, the owner must tap **Allow** on the phone.

### The scan is very slow

- `tailscale ping` may show `via DERP`, meaning traffic is relayed. It still
  works, just slower. A bugreport can take 15-30 minutes on a relay.
- Keep the phone on Wi-Fi rather than weak mobile data if possible.
- Do not run scrcpy at the same time as the bugreport.

### MVT fails to download indicators

- Check `mvt_iocs.log` in the case folder.
- Re-run the scan, or run the MVT command manually:

  ```powershell
  .\.venv\Scripts\mvt-android.exe download-iocs
  .\.venv\Scripts\mvt-android.exe check-bugreport .\cases\a16_*\bugreport.zip -o .\cases\mvt_manual
  ```

### Bugreport fails

- Free space on the phone (a few GB) and on the PC.
- Keep the phone unlocked; some OEMs pause long ADB operations when locked.
- Reconnect ADB and retry.

### Samsung-specific blockers

- **Auto Blocker**: Settings > Security and privacy > Auto Blocker. If it is
  on and ADB is refused, turn it off temporarily for the scan, then turn it
  back on afterwards.
- **Secure Wi-Fi**: this is a VPN. Turn it off; Android allows only one VPN.
- **Battery optimization**: Settings > Apps > Tailscale > Battery >
  Unrestricted. Also remove Tailscale from Sleeping apps / Deep sleeping apps.
- **Wireless debugging turns itself off** after a reboot or a network change.
  Re-enable it and use the new port.

---

## 12. Exact message to send the owner

Send `FOR-PHONE-OWNER.txt` as-is. It contains both the invite path and the
share path, plus the phone steps. Before sending, tell them which path you
chose and, for Path B, give them your Tailscale email.

A short WhatsApp-style message:

```
Hi - for the phone security check we agreed on, please install Tailscale
from the Play Store. I have invited your email / I need you to share the
phone with my Tailscale email: <your email>. Tell me when Tailscale says
"Connected". Then I will guide you through Developer options and Wireless
debugging. Keep the phone charged and unlocked during the check.
```

---

## 13. Security rules

- Only scan a phone you own or have explicit consent to examine.
- Never post pairing ports or codes in a group chat.
- Never port-forward ADB on the phone's router. Tailscale is the secure path.
- Prefer Path B if the owner should not see your other tailnet devices.
- Tailscale traffic is WireGuard-encrypted; ADB pairing is TLS-encrypted.
- Revoke the invite/share and turn off Wireless debugging after the scan.
- A clean scan is not proof of cleanliness; it means no known indicators were
  found in the collected data.
