# Autologin-VIT-Wifi

Version 1.2.0

A tiny macOS background agent that keeps a Mac signed in to the VIT hostel Wi-Fi.

The hostel network sits behind a Pronto sign-in page. Every time the connection drops, or the
Wi-Fi comes back after the nightly 1:30-3:30 AM shutdown, you have to open that page and type
your registration number and password again. This agent does it for you the moment the Wi-Fi is
back, and closes the macOS sign-in window too, so downloads, cloud notebooks and anything else
running overnight pick up again on their own. It uses only tools macOS already ships with.

## Features

- **Instant:** macOS tells the agent the moment the Wi-Fi comes back, and it signs in straight
  away, retrying every second while the network is still coming up. No fixed polling delay.
- **Closes the macOS sign-in window:** macOS keeps other apps off the hostel Wi-Fi until its own
  sign-in window is dealt with. The agent closes it the instant it appears, so every app is back
  online, not just the agent.
- **Hands-off:** starts at login, survives restarts, and launchd brings it back if it ever stops.
  No app to open, no terminal to keep open.
- **Keychain storage:** the password lives in the macOS login Keychain, never in a file or on a
  command line another process could read.
- **Never sends the password outside VIT:** it signs in only when the VIT sign-in page itself is
  intercepting the connection, and only to the portal's campus address.
- **Cooldown on rejection:** if the portal turns the sign-in down it waits 2 minutes before trying
  again, so a wrong or changed password is not sent over and over.
- **Quiet log:** records only changes (online, offline, signed in, rejected), trimmed to stay
  small.
- **Zero dependencies:** plain `bash`, `curl`, `scutil`, `security` and `launchd`. Nothing to
  install, no Homebrew, no app.

## Install

```sh
git clone https://github.com/AbGisHere/Autologin-VIT-Wifi.git
cd Autologin-VIT-Wifi
./install.sh
```

The installer asks for your registration number and then your Wi-Fi password twice (nothing is
shown while you type). It then:

1. stores the password in the login Keychain as `autologin-vit-wifi`
2. copies the script to `~/Library/Application Support/autologin-vit-wifi/`
3. installs and starts a LaunchAgent, `~/Library/LaunchAgents/com.local.autologin-vit-wifi.plist`,
   that keeps the script running in the background

macOS may show a "Background Items Added" notification for `bash`. Leave it enabled in
System Settings > General > Login Items & Extensions, otherwise it will not start after a
restart.

Run `./install.sh` again at any time to change the stored password or to update to a newer
version of the script. Your stored password is kept unless you choose to replace it.

## Usage

There is nothing to do day to day. To see what it is doing:

```sh
cd ~/Library/Application\ Support/autologin-vit-wifi
./autologin-vit-wifi.sh --status    # state, last check and recent log
./autologin-vit-wifi.sh --dry-run   # what it would do right now; never signs in
./autologin-vit-wifi.sh --version   # installed version
```

Example log, `~/Library/Logs/autologin-vit-wifi.log`:

```text
2026-10-17 01:30:14 offline: no answer from the internet or the VIT sign-in page (router 172.17.104.1, portal -)
2026-10-17 03:30:41 signed in as 25BCE0000 (portal HTTP 200); internet is back
2026-10-17 03:30:41 closed the macOS sign-in window
```

## How fast

| What happened | When the agent acts |
|---|---|
| Wi-Fi drops and comes back (nightly shutdown, roaming, Wi-Fi off/on) | The moment macOS reports the change, then every second until it is signed in |
| Mac wakes from sleep | Straight after waking, then every second while the Wi-Fi rejoins |
| Portal session ends while the Wi-Fi stays connected | On the next regular check, at most 10 seconds later |
| The macOS sign-in window opens | Closed within a fraction of a second, for a minute after each sign-in |

Measured on the hostel network: after a sign-out from the portal, the internet was back 8 seconds
later, without touching anything.

## How it works

The LaunchAgent runs `autologin-vit-wifi.sh --watch`. Through `scutil`, macOS reports every change
to the Wi-Fi's link, address and captive-portal state and to the default route, and the agent runs
a check as soon as one arrives. While the network is still coming up it repeats the check every
second for 30 seconds; otherwise it checks every 10 seconds.

Each check takes well under a second when you are online:

1. **Reach test.** Request `http://clients3.google.com/generate_204` over the Wi-Fi interface. A
   real internet connection answers HTTP 204, so the agent stops there. Right after the Wi-Fi
   joins, macOS withholds DNS from a network it thinks needs a sign-in, so if the test gets no
   answer the agent asks the Wi-Fi router for DNS directly and tries again.
2. **Check it is the VIT sign-in page.** Any other answer means something is intercepting the
   connection. The agent only continues if that something is the VIT portal: either the
   intercepted reply mentions `prontonetworks`, or the default router is a campus 172.16-31.x
   address and the portal answers on its private address `172.16.1.1`. On a home router, a cafe
   hotspot or a phone hotspot it does nothing.
3. **Sign in.** Submit the same three fields as the browser sign-in form (`userId`, `password`
   and `serviceName=ProntoAuthentication`) to `http://phc.prontonetworks.com/cgi-bin/authlogin`.
   The request always goes to the portal's campus address `172.16.1.1`, whatever DNS says, so the
   password never leaves the campus network. The password is piped to `curl` on stdin.
4. **Confirm.** Run the reach test again. HTTP 204 means the sign-in worked. If the portal
   answered but the internet is not reachable yet, the next check confirms; if that happens twice
   in a row, the sign-in counts as rejected, the log shows what the portal page said, and the
   agent cools down for 2 minutes. If the sign-in got no answer at all, the Wi-Fi is still coming
   up, so it simply tries again a second later, without a cooldown.
5. **Release the macOS hold.** macOS keeps other apps off a network it thinks needs a sign-in
   until its own sign-in window is dealt with. The agent closes that window if it is open, and
   because the sign-in often beats the window, keeps watching for it for a minute and closes it
   the moment it appears. macOS then re-checks, sees the network is signed in and releases it to
   every app in under a second. Nothing waits on this. If macOS is somehow still holding the
   network 10 seconds after the sign-in, the agent turns Wi-Fi off and on once; the portal session
   survives the rejoin.

## Troubleshooting

| `--status` says | Meaning and fix |
|---|---|
| `online` | All good. |
| `offline` | No network at all, for example during the 1:30-3:30 shutdown. It signs in by itself once the Wi-Fi is back. |
| `waiting` | The portal took the sign-in but the internet was not reachable yet. The next check, 10 seconds later, confirms. |
| `no-reply` | The Wi-Fi was still coming up and the sign-in got no answer. It tries again a second later. |
| `rejected` | The portal turned the sign-in down; the log line shows what its page said. If it is the password, run `./install.sh` and store the current one. |
| `no-password` | Nothing stored in the Keychain. Run `./install.sh`. |
| `other-network` | The connection is intercepted, but not by the VIT portal, so it did not sign in. Expected on other networks. |
| Nothing after a restart | Check that the `bash` background item is enabled under Login Items & Extensions. |
| Anything unexpected | `--status` also prints `last:`, the details of the last check that was not online (reach test result, router, DNS answer, portal answer). |

## Limits

- **The Mac has to be awake.** A sleeping Mac runs nothing; it signs in right after waking. To
  stay awake overnight on the charger, enable System Settings > Battery > Options > "Prevent
  automatic sleeping on power adapter when the display is off", or keep `caffeinate -dis`
  running in a terminal. Closing the lid still sleeps the Mac unless an external display is
  connected.
- **It handles the sign-in, not the Wi-Fi itself.** macOS rejoins the network on its own when it
  comes back. The one exception is the rare off/on fallback described above.
- **The macOS sign-in window may flash up** for a moment when the Wi-Fi comes back. Leave it
  alone; the agent closes it. If you type into it yourself, that works too.
- **The portal is plain HTTP**, the same as the browser sign-in page. That is the portal's design,
  not this tool's.
- **Pronto only.** If VIT changes the portal host or address, update `PORTAL_HOST` and
  `PORTAL_IP` at the top of `autologin-vit-wifi.sh` and run `./install.sh` again.

## Uninstall

```sh
./uninstall.sh
```

This removes the LaunchAgent, the installed script and the Keychain item. The log at
`~/Library/Logs/autologin-vit-wifi.log` is kept; delete it by hand if you like.

## Files

| File | Purpose |
|---|---|
| `autologin-vit-wifi.sh` | The agent: watches the Wi-Fi, checks, signs in and closes the macOS sign-in window |
| `install.sh` | Stores the password, installs or updates the script and starts the agent |
| `uninstall.sh` | Removes everything except the log |

This is an independent project, not affiliated with VIT or Pronto Networks.

## License

[MIT](LICENSE)
