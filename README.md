# Autologin-VIT-Wifi

Version 1.1.0

A tiny macOS background agent that keeps a Mac signed in to the VIT hostel Wi-Fi.

The hostel network sits behind a Pronto sign-in page: every time the connection drops, or the
Wi-Fi comes back after the nightly 1:30-3:30 AM shutdown, you have to open that page and type
your registration number and password again. This agent signs you back in within a few seconds
of the Wi-Fi returning, so downloads, cloud notebooks and anything else running overnight pick
up again on their own. It uses only tools macOS already ships with.

## Features

- **Fast:** notices within a second when the Wi-Fi gets an address or the Mac wakes, signs in
  straight away and retries every second while the network is still coming up.
- **Hands-off:** starts at login and after a restart, and launchd restarts it if it ever stops.
  No app to open, no terminal to keep open.
- **Gets past the macOS sign-in window:** macOS holds the hostel Wi-Fi back from other apps until
  its own sign-in window is dealt with. The agent signs in anyway and then closes that window, so
  you never have to touch it.
- **Keychain storage:** the password lives in the macOS login Keychain, never in a file or in a
  command line another process could read.
- **Never sends the password outside VIT:** it signs in only when the VIT sign-in page itself is
  intercepting the connection (see [How it works](#how-it-works)).
- **Cooldown on rejection:** if the portal turns the sign-in down it waits 2 minutes before trying
  again, so a wrong or changed password is not sent over and over.
- **Quiet log:** records only changes (online, offline, signed in, rejected), trimmed to stay
  small.
- **Zero dependencies:** plain `bash`, `curl`, `security` and `launchd`. Nothing to install, no
  Java, no Homebrew.

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
   that keeps the script running in `--watch` mode

macOS may show a "Background Items Added" notification for `bash`. Leave it enabled in
System Settings > General > Login Items & Extensions, otherwise it will not start after a
restart.

Run `./install.sh` again at any time to change the stored password.

## Usage

There is nothing to do day to day. To see what it is doing:

```sh
~/Library/Application\ Support/autologin-vit-wifi/autologin-vit-wifi.sh --status    # state + recent log
~/Library/Application\ Support/autologin-vit-wifi/autologin-vit-wifi.sh --dry-run   # what it would do now; never signs in
~/Library/Application\ Support/autologin-vit-wifi/autologin-vit-wifi.sh --version   # installed version
```

Example log, `~/Library/Logs/autologin-vit-wifi.log`:

```text
2026-10-17 01:30:14 offline: no answer from the internet or the VIT sign-in page (router 172.17.104.1, portal -)
2026-10-17 03:30:41 signed in as 25BCE0000 (portal HTTP 200); internet is back
2026-10-17 03:30:42 closed the macOS sign-in window; network released
```

## How it works

The LaunchAgent runs `autologin-vit-wifi.sh --watch`, a loop that wakes once a second and asks
macOS for the Wi-Fi address (one `ipconfig` call, nothing on the network). When the address
changes, or the Mac has just woken up, it runs a check at once, and then again every second for
30 seconds while the network is still coming up. Otherwise it runs a check every 10 seconds.

Each check takes well under a second when you are online:

1. **Reach test.** Request `http://clients3.google.com/generate_204` over the Wi-Fi interface. A
   real internet connection answers HTTP 204, so the agent stops there. Right after the Wi-Fi
   joins, macOS withholds DNS from a network it thinks needs a sign-in, so if the test gets no
   answer the agent asks the Wi-Fi router for DNS directly and tries again.
2. **Check it is the VIT sign-in page.** Any other answer means something is intercepting the
   connection. The agent only continues if that something is the VIT portal: either the
   intercepted reply mentions `prontonetworks`, or the default router is a campus
   172.16-31.x address and the portal answers on its private address `172.16.1.1`. On a home
   router, a cafe hotspot or a phone hotspot it does nothing.
3. **Sign in.** Submit the same three fields as the browser sign-in form (`userId`, `password`
   and `serviceName=ProntoAuthentication`) to `http://phc.prontonetworks.com/cgi-bin/authlogin`.
   The request always goes to the portal's campus address `172.16.1.1`, whatever DNS says, so the
   password never leaves the campus network. The password is piped to `curl` on stdin.
4. **Confirm.** Run the reach test again. HTTP 204 means the sign-in worked. If the portal
   answered but the internet is not reachable yet, the next check confirms; if that happens twice
   in a row, the sign-in counts as rejected, the log shows what the portal page said, and the
   agent cools down for 2 minutes.
5. **Release the macOS hold.** If ordinary apps still cannot get out (macOS is waiting on its
   sign-in window), the agent closes that window. macOS then checks the network again, sees that
   it is already signed in and brings it up for everything, in under a second. If that is not
   enough, it turns Wi-Fi off and on once instead; the portal session survives the rejoin.

If the sign-in gets no answer at all, the Wi-Fi is still coming up, so it simply tries again on
the next check, without a cooldown. The same goes for no network at all, as during the night
shutdown.

The sign-in can now land before macOS has even opened its sign-in window. Nothing waits for it:
the agent closes the window if it is already open, and for a minute after the sign-in it looks for
it five times a second and closes it the moment it appears. Once you are signed in the window has
nothing left to do. If macOS is still holding the network 10 seconds after the sign-in, the agent
turns Wi-Fi off and on once.

Before 1.1.0 the agent ran every 10 seconds, and launchd will not start a job more often than
that, so a check that came too early cost another 10 seconds: every app was online again 24 to
27 seconds after the Wi-Fi came back. Now the sign-in follows as soon as macOS has rejoined the
Wi-Fi and the portal answers.

## Troubleshooting

| `--status` says | Meaning and fix |
|---|---|
| `online` | All good. |
| `offline` | No network at all, for example during the 1:30-3:30 shutdown. It signs in by itself once the Wi-Fi is back. |
| `waiting` | The portal took the sign-in but the internet was not reachable yet. The next check, 10 seconds later, confirms. |
| `no-reply` | The Wi-Fi was still coming up and the sign-in got no answer. It tries again on the next check. |
| `rejected` | The portal turned the sign-in down; the log line shows what its page said. If it is the password, run `./install.sh` and store the current one. |
| `no-password` | Nothing stored in the Keychain. Run `./install.sh`. |
| `other-network` | The connection is intercepted, but not by the VIT portal, so it did not sign in. Expected on other networks. |
| Nothing after a restart | Check that the `bash` background item is enabled under Login Items & Extensions. |
| Anything unexpected | `--status` also prints `last:`, the details of the last check that was not online (reach test result, router, DNS answer, portal answer). |

## Limits

- **The Mac has to be awake.** A sleeping Mac runs nothing; it signs in a few seconds after
  waking. To stay awake overnight on the charger, enable System Settings > Battery > Options >
  "Prevent automatic sleeping on power adapter when the display is off", or keep `caffeinate -dis`
  running in a terminal. Closing the lid still sleeps the Mac unless an external display is
  connected.
- **It handles the sign-in, not the Wi-Fi itself.** macOS rejoins the network on its own when it
  comes back. The one exception is the fallback off/on after a sign-in, described above.
- **The macOS sign-in window may flash up** when the Wi-Fi comes back. Leave it alone; the agent
  closes it. If you type into it yourself, that works too.
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
| `autologin-vit-wifi.sh` | The check-and-sign-in script the agent runs |
| `install.sh` | Stores the password, installs and starts the agent |
| `uninstall.sh` | Removes everything |

This is an independent project, not affiliated with VIT or Pronto Networks.

## License

[MIT](LICENSE)
