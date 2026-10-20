#!/bin/bash
# Autologin-VIT-Wifi: keeps a Mac signed in to the VIT hostel Wi-Fi (Pronto sign-in page).
#
# A LaunchAgent (see install.sh) keeps "--watch" running. It notices within a second when the
# Wi-Fi gets an address or the Mac wakes, and then runs a check at once, retrying every second
# while the network is still coming up; otherwise it checks every 10 s. Each check:
#   1. runs a reach test against http://clients3.google.com/generate_204; HTTP 204 means the
#      internet is reachable, so it exits
#   2. otherwise checks that the thing in the way is the VIT sign-in page, so the password is
#      never sent anywhere else
#   3. submits the stored registration number and password, as the browser sign-in form does
#   4. runs the reach test again and logs whether the internet is back
#   5. if macOS is still holding the network behind its own sign-in window, closes that window
#      (or, failing that, rejoins the Wi-Fi once)
#
# The password lives in the macOS login Keychain (service "autologin-vit-wifi"), never in a file.
#
#   autologin-vit-wifi.sh            one check, sign in if needed
#   autologin-vit-wifi.sh --watch    keep checking (what the LaunchAgent runs)
#   autologin-vit-wifi.sh --dry-run  say what it would do, never send the password
#   autologin-vit-wifi.sh --status   print the state and the last log lines
#   autologin-vit-wifi.sh --version  print the version

set -u

VERSION="1.1.0"
SERVICE="autologin-vit-wifi"
PORTAL_HOST="phc.prontonetworks.com"
PORTAL_IP="172.16.1.1"     # what PORTAL_HOST resolves to on the VIT network
SIGNIN_PATH="/cgi-bin/authlogin?URI=http://example.com"
REACH_URL="${REACH_URL:-http://clients3.google.com/generate_204}"
COOLDOWN_S=120             # pause after a rejected sign-in so a wrong password is not repeated
CHECK_EVERY_S=10           # --watch: time between checks while nothing changes
BURST_S=30                 # --watch: after the Wi-Fi comes up, retry every second for this long
CNA_WATCH_S=60             # --watch: after a sign-in, close a late macOS sign-in window for this long
CNA="Captive Network Assistant"

STATE_DIR="$HOME/Library/Application Support/autologin-vit-wifi"
LOG="$HOME/Library/Logs/autologin-vit-wifi.log"
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Log a state only when it changes, so the log stays short.
set_state() {
  local old=""
  [ -f "$STATE_DIR/state" ] && old=$(cat "$STATE_DIR/state")
  if [ "$old" != "$1" ]; then
    echo "$1" > "$STATE_DIR/state"
    log "$1${2:+: $2}"
  fi
}

# Keep the log under about 2000 lines.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ]; then
  tail -1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

DRY_RUN=0
WATCH=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --watch) WATCH=1 ;;
  --version) echo "Autologin-VIT-Wifi $VERSION"; exit 0 ;;
  --status)
    echo "version: $VERSION"
    echo "state: $(cat "$STATE_DIR/state" 2>/dev/null || echo unknown)"
    echo "user:  $(security find-generic-password -s "$SERVICE" 2>/dev/null | awk -F'"' '/"acct"/{print $4}')"
    echo "last:  $(cat "$STATE_DIR/last_check" 2>/dev/null || echo "online at every check so far")"
    echo "log:   $LOG"
    tail -15 "$LOG" 2>/dev/null
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run|--watch|--status|--version]" >&2; exit 2 ;;
esac

# While macOS shows its own Wi-Fi sign-in window it keeps the network out of the routing table
# (no default route, no DNS), so ordinary requests fail. Binding every request to the Wi-Fi
# interface and asking the Wi-Fi router for DNS works in that state too, exactly as that window
# itself reaches the sign-in page.
WIFI_IF=$(networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
WIFI_IF=${WIFI_IF:-en0}

# --watch: a cheap one-second loop (one ipconfig call) that runs a full check in a child process
# as soon as the Wi-Fi gets a new address or the Mac wakes, then every second while the network
# is still coming up (offline / no-reply), and every CHECK_EVERY_S otherwise. Fast retries are
# only for those two states: "waiting" needs a few seconds for macOS to let go, and two quick
# "waiting" runs in a row would count as a rejected sign-in.
if [ $WATCH = 1 ]; then
  last_ip="-"; next_check=0; burst_until=0
  while true; do
    now=$(date +%s)
    ip=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null)
    if [ "$ip" != "$last_ip" ]; then
      last_ip=$ip
      next_check=0
      [ -n "$ip" ] && burst_until=$((now + BURST_S))
    fi

    if [ "$now" -ge "$next_check" ]; then
      /bin/bash "$0"
      now=$(date +%s)
      case "$(cat "$STATE_DIR/state" 2>/dev/null)" in
        offline|no-reply) [ "$now" -lt "$burst_until" ] && next_check=$((now + 1)) || next_check=$((now + CHECK_EVERY_S)) ;;
        *) next_check=$((now + CHECK_EVERY_S)) ;;
      esac
    fi

    # macOS can open its sign-in window a moment after we have already signed in. It has nothing
    # left to do then, and it keeps holding the network for other apps, so close it.
    signed_in_at=$(cat "$STATE_DIR/signed_in_at" 2>/dev/null || echo 0)
    if [ $((now - signed_in_at)) -lt $CNA_WATCH_S ] && pgrep -xq "$CNA"; then
      killall "$CNA" 2>/dev/null && log "closed the macOS sign-in window that opened after the sign-in"
    fi

    before=$(date +%s)
    sleep 1
    # A long sleep means the Mac was asleep: check now, and retry fast while the Wi-Fi rejoins.
    if [ $(($(date +%s) - before)) -gt 5 ]; then
      next_check=0
      burst_until=$(($(date +%s) + BURST_S))
    fi
  done
fi
wifi_ip=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null)
wifi_router=$(ipconfig getoption "$WIFI_IF" router 2>/dev/null)
IF_OPT=""
[ -n "$wifi_ip" ] && IF_OPT="--interface $WIFI_IF"

# resolve HOST -> IPv4 address, from the system resolver or else straight from the Wi-Fi router
resolve() {
  local ip
  ip=$(dig +short +time=2 +tries=1 "$1" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  if [ -z "$ip" ] && [ -n "$wifi_ip" ] && [ -n "$wifi_router" ]; then
    ip=$(dig +short +time=2 +tries=1 -b "$wifi_ip" "@$wifi_router" "$1" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  fi
  printf '%s' "$ip"
}

# reach_test -> sets REACH_CODE ("000" when there is no answer at all) and REACH_TEXT
# (headers + body)
reach_test() {
  local out
  out=$(curl -s -i --max-time 5 $IF_OPT -w '\n__CODE__%{http_code}' "$REACH_URL" 2>/dev/null)
  if [ -z "$out" ] || printf '%s' "$out" | grep -q '^__CODE__000'; then
    # No answer: maybe only DNS is missing (macOS sign-in window state). Retry with the
    # router's DNS.
    local host ip
    host=$(printf '%s' "$REACH_URL" | sed -E 's#^https?://([^/:]+).*#\1#')
    ip=$(resolve "$host")
    [ -n "$ip" ] && out=$(curl -s -i --max-time 5 $IF_OPT --resolve "$host:80:$ip" \
      -w '\n__CODE__%{http_code}' "$REACH_URL" 2>/dev/null)
  fi
  REACH_CODE=$(printf '%s' "$out" | sed -n 's/^__CODE__//p' | tail -1)
  REACH_TEXT=$(printf '%s' "$out" | head -c 20000)
  [ -n "$REACH_CODE" ] || REACH_CODE="000"
}

# macOS withholds DNS (and sometimes the route) from a network it saw as needing sign-in until
# its own sign-in window is dealt with, even after the portal has let us through. Closing the
# window makes macOS re-check at once (under a second); if that is not enough, rejoining the
# Wi-Fi makes it check again from scratch. The portal session survives both.
system_online() {
  # A plain request, with the system's own routing and DNS, is what every other app sees.
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$REACH_URL" 2>/dev/null)" = "204" ]
}
release_macos_hold() {
  # We are signed in, so the window has nothing left to do: close it whether or not macOS still
  # holds the network. The sign-in can now beat the window, so give it a few seconds to show up
  # before deciding that it is not the thing holding the network.
  local i j
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -xq "$CNA"; then
      killall "$CNA" 2>/dev/null
      for j in 1 2 3 4 5 6 7 8 9 10; do
        system_online && { log "closed the macOS sign-in window; network released"; return 0; }
        sleep 0.5
      done
      break
    fi
    system_online && return 0
    sleep 0.5
  done
  system_online && return 0
  log "macOS is still holding the network; rejoining Wi-Fi ($WIFI_IF)"
  networksetup -setairportpower "$WIFI_IF" off
  networksetup -setairportpower "$WIFI_IF" on
}

prev=$(cat "$STATE_DIR/state" 2>/dev/null)

reach_test
if [ "$REACH_CODE" = "204" ]; then
  set_state online
  [ $DRY_RUN = 1 ] && echo "online, nothing to do"
  # A sign-in sent on the last run went through; make sure macOS lets the other apps out too.
  [ $DRY_RUN = 0 ] && [ "$prev" = "waiting" ] && date +%s > "$STATE_DIR/signed_in_at" && release_macos_hold
  exit 0
fi

# Is this the VIT sign-in page? Either the intercepted reply points at Pronto, or the default
# router is a 172.16-31.x campus address and the sign-in host answers on its private IP. Right
# after a wake the portal often drops or stalls the reach test instead of redirecting it, so the
# second check does not rely on the reach test at all.
router=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
[ -z "$router" ] && router=$wifi_router
resolved=$(resolve "$PORTAL_HOST")
portal_code="-"
on_vit=0
if printf '%s' "$REACH_TEXT" | grep -qiE "prontonetworks|$PORTAL_IP"; then
  on_vit=1
elif printf '%s' "$router" | grep -qE '^172\.(1[6-9]|2[0-9]|3[01])\.' &&
     { [ "$resolved" = "$PORTAL_IP" ] || [ -z "$resolved" ]; }; then
  # Any HTTP answer from the sign-in address counts, whatever the status code.
  portal_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 $IF_OPT \
    --resolve "$PORTAL_HOST:80:$PORTAL_IP" "http://$PORTAL_HOST/" 2>/dev/null)
  [ -n "$portal_code" ] && [ "$portal_code" != "000" ] && on_vit=1
fi

# One line per run that is not online, so the last check can always be inspected.
printf '%s reach=%s router=%s dns=%s portal=%s on_vit=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
  "$REACH_CODE" "${router:-none}" "${resolved:-none}" "$portal_code" "$on_vit" > "$STATE_DIR/last_check"

if [ $on_vit = 0 ]; then
  if [ "$REACH_CODE" = "000" ]; then
    set_state offline "no answer from the internet or the VIT sign-in page (router ${router:-none}, portal ${portal_code})"
  else
    set_state other-network "reach test got HTTP $REACH_CODE, but not from the VIT sign-in page; not signing in"
  fi
  [ $DRY_RUN = 1 ] && echo "not on the VIT network (reach test HTTP $REACH_CODE, router ${router:-none}, portal ${portal_code}); nothing to do"
  exit 0
fi

# Pause after a rejected sign-in.
now=$(date +%s)
rejected_at=$(cat "$STATE_DIR/rejected_at" 2>/dev/null || echo 0)
if [ $DRY_RUN = 0 ] && [ $((now - rejected_at)) -lt $COOLDOWN_S ]; then
  exit 0
fi

user=$(security find-generic-password -s "$SERVICE" 2>/dev/null | awk -F'"' '/"acct"/{print $4}')
if [ -z "$user" ]; then
  [ $DRY_RUN = 1 ] && echo "on the VIT network and offline (reach test HTTP $REACH_CODE), but no password is stored"
  set_state no-password "run install.sh to store your registration number and password"
  exit 1
fi

if [ $DRY_RUN = 1 ]; then
  echo "on the VIT network and offline (reach test HTTP $REACH_CODE): would sign in as $user"
  exit 0
fi

password=$(security find-generic-password -s "$SERVICE" -w 2>/dev/null)
if [ -z "$password" ]; then
  set_state no-password "could not read the password from the Keychain"
  exit 1
fi

# Always send the sign-in to the portal's private campus address. macOS's resolver can return a
# public address for the portal host (cached from another network, or via encrypted DNS), and
# the password must never leave the campus network.
pin_opt="--resolve $PORTAL_HOST:80:$PORTAL_IP $IF_OPT"

# The password goes to curl on stdin, so it never shows up in the process list. These are the
# fields the browser sign-in form submits.
response=$(printf '%s' "$password" | curl -sS --max-time 10 $pin_opt \
  -A "Mozilla/5.0 (Macintosh)" \
  --data-urlencode "userId=$user" \
  --data-urlencode "password@-" \
  --data "serviceName=ProntoAuthentication" \
  -w '\n__CODE__%{http_code}' \
  "http://$PORTAL_HOST$SIGNIN_PATH" 2>"$STATE_DIR/signin_error")
unset password
code=$(printf '%s' "$response" | sed -n 's/^__CODE__//p' | tail -1)

sleep 1
reach_test
if [ "$REACH_CODE" = "204" ]; then
  rm -f "$STATE_DIR/rejected_at"
  date +%s > "$STATE_DIR/signed_in_at"
  echo online > "$STATE_DIR/state"
  log "signed in as $user (portal HTTP ${code:-none}); internet is back"
  release_macos_hold
  exit 0
fi

# No answer at all: the Wi-Fi is still coming up. Try again on the next run, without pausing.
if [ -z "$code" ] || [ "$code" = "000" ]; then
  set_state no-reply "the sign-in got no answer ($(head -c 150 "$STATE_DIR/signin_error")); trying again on the next check"
  exit 0
fi

# The portal answered but the reach test still cannot get out. The first time, macOS is most
# likely still holding the network behind its sign-in window and lets go within a few seconds,
# so the next run confirms. If it happens twice in a row, the portal turned the sign-in down.
if [ "$prev" != "waiting" ] && { [ "$code" = "200" ] || [ "$code" = "302" ]; }; then
  echo waiting > "$STATE_DIR/state"
  log "sent the sign-in as $user (portal HTTP $code); waiting for the network to come up"
  exit 0
fi

# Show what the portal page says, with the HTML stripped, so a wrong password is easy to spot.
page_says=$(printf '%s' "$response" | sed 's/__CODE__.*//' | sed -e 's/<[^>]*>/ /g' |
  tr -s '[:space:]' ' ' | sed 's/^ //' | head -c 120)
echo "$now" > "$STATE_DIR/rejected_at"
set_state rejected "portal HTTP ${code:-none}${page_says:+, page says \"$page_says\"}; trying again in ${COOLDOWN_S}s"
exit 1
