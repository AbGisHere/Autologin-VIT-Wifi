#!/bin/bash
# Autologin-VIT-Wifi: keeps a Mac signed in to the VIT hostel Wi-Fi (Pronto sign-in page).
#
# A LaunchAgent (see install.sh) keeps "--watch" running. macOS tells it the moment the Wi-Fi
# changes (link, address or captive-portal state), and it runs a check at once, retrying every
# second while the network is still coming up; otherwise it checks every 10 s. Each check:
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
HOLD_S=10                  # --watch: rejoin Wi-Fi if macOS still holds the network this long after it
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
# Called right after a sign-in. Never waits: if the window is up, close it now. A window that
# opens later, and the rare case where macOS keeps holding the network, are left to --watch.
release_macos_hold() {
  pgrep -xq "$CNA" && killall "$CNA" 2>/dev/null && log "closed the macOS sign-in window"
}
rejoin_wifi() {
  log "macOS is still holding the network; rejoining Wi-Fi ($WIFI_IF)"
  networksetup -setairportpower "$WIFI_IF" off
  networksetup -setairportpower "$WIFI_IF" on
}

# Prints a "changedKey" line the moment macOS changes the Wi-Fi's link, address or captive-portal
# state (CaptiveNetwork is where macOS records that it found a sign-in page), or the default
# route. The blank line every minute is ignored by scutil; once scutil or this script is gone,
# writing it fails or the loop ends, so nothing is left behind.
watch_network_changes() {
  {
    printf 'n.add State:/Network/Interface/%s/%s\n' "$WIFI_IF" Link "$WIFI_IF" IPv4 "$WIFI_IF" CaptiveNetwork
    printf 'n.add State:/Network/Global/IPv4\nn.watch\n'
    while kill -0 $$ 2>/dev/null; do sleep 60; echo; done
  } | scutil
}

# --watch: a cheap loop that waits on watch_network_changes and runs a full check in a child
# process the moment the Wi-Fi changes or the Mac wakes, then every second while the network is
# still coming up (offline / no-reply), and every CHECK_EVERY_S otherwise. Fast retries are
# only for those two states: "waiting" needs a few seconds for macOS to let go, and two quick
# "waiting" runs in a row would count as a rejected sign-in.
#
# For CNA_WATCH_S after a sign-in it looks for the macOS sign-in window five times a second and
# closes it the moment it appears: the sign-in can beat the window, which then has nothing left
# to do but hold the network back from other apps. If macOS still holds the network HOLD_S after
# the sign-in, it rejoins the Wi-Fi once.
if [ $WATCH = 1 ]; then
  next_check=0; burst_until=0; settled_for=""; watcher=""; changed=0
  events="$STATE_DIR/events"
  trap '[ -n "$watcher" ] && pkill -P "$watcher"; [ -n "$watcher" ] && kill "$watcher" 2>/dev/null' EXIT
  trap 'exit 0' TERM INT HUP
  while true; do
    # (Re)start the watcher. It only stops if scutil does, so this is normally once.
    if [ -z "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
      [ -n "$watcher" ] && sleep 1
      exec 3<&-
      rm -f "$events" && mkfifo "$events"
      watch_network_changes > "$events" &
      watcher=$!
      exec 3< "$events"
    fi

    now=$(date +%s)
    if [ $changed = 1 ]; then
      changed=0
      # Not after a "waiting" check: a second one straight away would count as a rejection.
      [ "$(cat "$STATE_DIR/state" 2>/dev/null)" != waiting ] && next_check=0
      burst_until=$((now + BURST_S))
    fi

    if [ "$now" -ge "$next_check" ]; then
      /bin/bash "$0"
      now=$(date +%s)
      case "$(cat "$STATE_DIR/state" 2>/dev/null)" in
        offline|no-reply) [ "$now" -lt "$burst_until" ] && next_check=$((now + 1)) || next_check=$((now + CHECK_EVERY_S)) ;;
        *) next_check=$((now + CHECK_EVERY_S)) ;;
      esac
    fi

    nap=1
    signed_in_at=$(cat "$STATE_DIR/signed_in_at" 2>/dev/null || echo 0)
    since=$((now - signed_in_at))
    if [ $since -lt $CNA_WATCH_S ]; then
      nap=0.2
      pgrep -xq "$CNA" && killall "$CNA" 2>/dev/null && log "closed the macOS sign-in window"
      if [ $since -ge $HOLD_S ] && [ "$settled_for" != "$signed_in_at" ]; then
        settled_for=$signed_in_at
        system_online || rejoin_wifi
      fi
    fi

    before=$(date +%s)
    if [ $nap = 1 ]; then
      # Wait up to a second for a change. (bash 3.2 only takes whole seconds here.)
      read -t 1 -u 3 line && case "$line" in *changedKey*) changed=1 ;; esac
    else
      sleep $nap
    fi
    # A long sleep means the Mac was asleep: check now, and retry fast while the Wi-Fi rejoins.
    if [ $(($(date +%s) - before)) -gt 5 ]; then
      next_check=0
      burst_until=$(($(date +%s) + BURST_S))
    fi
  done
fi

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
