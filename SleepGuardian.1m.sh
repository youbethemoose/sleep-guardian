#!/bin/bash

# <bitbar.title>Sleep Guardian</bitbar.title>
# <bitbar.version>3.1</bitbar.version>
# <bitbar.author>Robby Mueller</bitbar.author>
# <bitbar.desc>Auto keep-awake based on home network. Timed sessions when home.</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>

# ════════════════════════════════════════════════
#  CONFIGURE THIS — your home router MAC addresses
#  One per line inside the parentheses. Add a new one
#  when you swap routers (or keep the old one too).
#  To find it: arp -n 192.168.1.1 | awk '{print $4}'
# ════════════════════════════════════════════════
HOME_ROUTER_MACS=(
    "xx:xx:xx:xx:xx:xx"  # ← replace with your router's MAC
)

# ════════════════════════════════════════════════
#  Internal — do not edit below this line
# ════════════════════════════════════════════════
SESSION_FILE="$HOME/.sleep-guardian-session"
CAFFEINATE_PID_FILE="$HOME/.sleep-guardian-caff.pid"
LOCATION_FILE="$HOME/.sleep-guardian-location"
SCRIPT_PATH="$0"

# ── Helpers ─────────────────────────────────────

# Lowercases and zero-pads each octet, since arp sometimes
# prints "8:3:..." instead of "08:03:...".
normalize_mac() {
    echo "$1" | tr 'A-F' 'a-f' | awk -F: '{
        for (i = 1; i <= NF; i++) { o = $i; if (length(o) == 1) o = "0" o; printf "%s%s", (i > 1 ? ":" : ""), o }
    }'
}

# Gets the MAC address of the default gateway (your router),
# works on WiFi and ethernet, needs no special permissions.
# We ping first to ensure the ARP table is populated,
# then read from it — all local, no internet required.
get_router_mac() {
    local gateway
    gateway=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    [ -z "$gateway" ] && echo "" && return

    # Ping once silently to populate ARP cache (instant, local only)
    ping -c 1 -W 1 "$gateway" &>/dev/null

    normalize_mac "$(arp -n "$gateway" 2>/dev/null | awk '/:.+:.+:/{print $4}' | head -1)"
}

is_home_network() {
    local mac home
    mac=$(get_router_mac)
    [ -z "$mac" ] && return 1
    for home in "${HOME_ROUTER_MACS[@]}"; do
        [ "$mac" = "$(normalize_mac "$home")" ] && return 0
    done
    return 1
}

read_session() {
    [ -f "$SESSION_FILE" ] && cat "$SESSION_FILE" || echo ""
}

# Returns the PID from the pid file only if it's still our caffeinate.
# Guards against killing an unrelated process that reused the PID after a reboot.
caffeinate_pid() {
    [ -f "$CAFFEINATE_PID_FILE" ] || return 1
    local pid
    pid=$(cat "$CAFFEINATE_PID_FILE")
    [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "caffeinate" ] || return 1
    echo "$pid"
}

kill_caffeinate() {
    local pid
    pid=$(caffeinate_pid) && kill "$pid" 2>/dev/null
    rm -f "$CAFFEINATE_PID_FILE"
}

start_caffeinate() {
    local mode="$1"
    kill_caffeinate
    if [ "$mode" = "full" ]; then
        # Block display sleep AND system sleep — for on-set shooting days
        nohup caffeinate -d -i -m > /dev/null 2>&1 &
    else
        # Block system sleep only — display still sleeps normally
        nohup caffeinate -i -s -m > /dev/null 2>&1 &
    fi
    echo $! > "$CAFFEINATE_PID_FILE"
    disown $!
}

session_expired() {
    local type ends now
    type=$(echo "$1" | awk '{print $1}')
    ends=$(echo "$1" | awk '{print $2}')
    now=$(date +%s)
    [ "$type" = "timed" ] && [ "$now" -ge "$ends" ] && return 0
    return 1
}

format_remaining() {
    local now secs h m
    now=$(date +%s)
    secs=$(( $1 - now ))
    [ "$secs" -le 0 ] && echo "expiring..." && return
    h=$(( secs / 3600 ))
    m=$(( (secs % 3600) / 60 ))
    [ "$h" -gt 0 ] && printf "%dh %02dm" "$h" "$m" || printf "%dm" "$m"
}

# Asks macOS which sleep assertions our caffeinate actually holds.
verified_status() {
    local pid assertions display=false system=false
    pid=$(caffeinate_pid) || { echo "none"; return; }
    assertions=$(pmset -g assertions 2>/dev/null | grep "pid $pid(caffeinate)")
    echo "$assertions" | grep -q "PreventUserIdleDisplaySleep" && display=true
    echo "$assertions" | grep -qE "PreventUserIdleSystemSleep|PreventSystemSleep" && system=true
    if $display && $system; then echo "full"
    elif $system; then echo "system"
    else echo "none"
    fi
}

# Other apps currently holding a keep-awake assertion (excluding macOS itself and us).
other_blockers() {
    pmset -g assertions 2>/dev/null \
        | grep "pid [0-9]*(" \
        | grep -E "PreventUserIdle(Display|System)Sleep|NoIdleSleepAssertion|NoDisplaySleepAssertion|PreventSystemSleep" \
        | grep -vE "\((powerd|caffeinate|WindowServer|coreaudiod)\)" \
        | sed -E 's/.*pid [0-9]+\(([^)]+)\).*/\1/' \
        | sort -u | paste -sd ',' - | sed 's/,/, /g'
}

# ── Actions ─────────────────────────────────────

action_start_away() {
    echo "away 0 Away" > "$SESSION_FILE"
    start_caffeinate "full"
}

action_start_timed() {
    local ends
    ends=$(( $(date +%s) + $1 * 60 ))
    echo "timed $ends $2" > "$SESSION_FILE"
    start_caffeinate "system"
}

action_start_indefinite() {
    echo "indefinite 0 Indefinite" > "$SESSION_FILE"
    start_caffeinate "system"
}

action_stop() {
    rm -f "$SESSION_FILE"
    kill_caffeinate
}

# ── Handle SwiftBar menu clicks ──────────────────
case "$1" in
    start-away)       action_start_away;               exit 0 ;;
    start-30m)        action_start_timed 30  "30 min"; exit 0 ;;
    start-1h)         action_start_timed 60  "1 hr";   exit 0 ;;
    start-2h)         action_start_timed 120 "2 hrs";  exit 0 ;;
    start-4h)         action_start_timed 240 "4 hrs";  exit 0 ;;
    start-8h)         action_start_timed 480 "8 hrs";  exit 0 ;;
    start-indefinite) action_start_indefinite;         exit 0 ;;
    stop)             action_stop;                     exit 0 ;;
esac

# ── Startup delay — wait for network on fresh login ─
# Check how long the system has been up. If under 90 seconds,
# wait it out so WiFi/ethernet has time to connect and ARP
# table has time to populate before we check for home network.
UPTIME_SECS=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')
NOW=$(date +%s)
UPTIME=$(( NOW - UPTIME_SECS ))
if [ "$UPTIME" -lt 90 ]; then
    WAIT=$(( 90 - UPTIME ))
    sleep "$WAIT"
fi

# ── Main logic ───────────────────────────────────

SESSION=$(read_session)
SESSION_TYPE=$(echo "$SESSION" | awk '{print $1}')
SESSION_ENDS=$(echo "$SESSION" | awk '{print $2}')

# Auto-expire timed sessions
if [ "$SESSION_TYPE" = "timed" ] && session_expired "$SESSION"; then
    action_stop
    SESSION=""
    SESSION_TYPE=""
fi

caffeinate_pid >/dev/null && CAFF_RUNNING=true || CAFF_RUNNING=false

# Detect home vs away. Leaving home needs two misses in a row (~1 min),
# so a brief Wi-Fi blip at home doesn't cancel a running session.
PREV_LOCATION=$(cat "$LOCATION_FILE" 2>/dev/null)
if is_home_network; then
    LOCATION="home"
elif [ "$PREV_LOCATION" = "home" ]; then
    LOCATION="leaving"
else
    LOCATION="away"
fi
echo "$LOCATION" > "$LOCATION_FILE"
[ "$LOCATION" = "away" ] && AT_HOME=false || AT_HOME=true

# Just left home: whatever home session was running gets replaced by
# Away mode, so the display stays on at the studio / on set.
if ! $AT_HOME && [ "$PREV_LOCATION" = "leaving" ] && [ "$SESSION_TYPE" != "away" ]; then
    action_start_away
    SESSION_TYPE="away"
fi

# Auto-start full block when away and no session running
if ! $AT_HOME && [ -z "$SESSION_TYPE" ]; then
    action_start_away
    SESSION_TYPE="away"
fi

# Just got home: end the automatic away session. Only on arrival, so
# "Force Away mode" still works when you start it at home.
if $AT_HOME && [ "$PREV_LOCATION" = "away" ] && [ "$SESSION_TYPE" = "away" ]; then
    action_stop
    SESSION_TYPE=""
fi

# Revive caffeinate if it died unexpectedly
if [ -n "$SESSION_TYPE" ] && ! $CAFF_RUNNING; then
    [ "$SESSION_TYPE" = "away" ] && start_caffeinate "full" || start_caffeinate "system"
    sleep 0.3  # give macOS a moment to register the assertion before we verify it
fi

# ── Menubar title (SF Symbols) ───────────────────
case "$SESSION_TYPE" in
    away)             echo ":camera:" ;;
    timed|indefinite) echo ":cup.and.saucer:" ;;
    *)                $AT_HOME && echo ":house:" || echo ":camera:" ;;
esac

echo "---"

# ── Dropdown ─────────────────────────────────────

$AT_HOME && echo "Home network detected | sfimage=location.fill" \
         || echo "Away from home | sfimage=location.fill"

if [ "$SESSION_TYPE" = "away" ]; then
    echo "Away session active | sfimage=bolt.fill"
    echo "Display + system sleep: BLOCKED | color=#fbbf24"
elif [ "$SESSION_TYPE" = "timed" ]; then
    echo "Timed session — $(format_remaining "$SESSION_ENDS") remaining | sfimage=timer"
    echo "System sleep: BLOCKED  /  Display: sleeps normally | color=#fbbf24"
elif [ "$SESSION_TYPE" = "indefinite" ]; then
    echo "Indefinite session active | sfimage=infinity"
    echo "System sleep: BLOCKED  /  Display: sleeps normally | color=#fbbf24"
else
    echo "No session — Mac sleeps normally | sfimage=moon.zzz color=#6b7280"
fi

# Confirm with macOS that the block is really in place
if [ -n "$SESSION_TYPE" ]; then
    EXPECTED="system"; [ "$SESSION_TYPE" = "away" ] && EXPECTED="full"
    VERIFIED=$(verified_status)
    if [ "$VERIFIED" = "$EXPECTED" ]; then
        echo "Confirmed by macOS | sfimage=checkmark.seal.fill color=#22c55e"
    else
        echo "macOS isn't reporting the block — try Refresh | sfimage=exclamationmark.triangle.fill color=#ef4444"
    fi
fi

OTHERS=$(other_blockers)
[ -n "$OTHERS" ] && echo "Also keeping Mac awake: $OTHERS | sfimage=info.circle color=#6b7280 size=12"

echo "---"

if [ -n "$SESSION_TYPE" ]; then
    echo "End Session | sfimage=stop.circle bash=\"$SCRIPT_PATH\" param1=stop terminal=false refresh=true"
    echo "---"
fi

if $AT_HOME; then
    echo "START TIMED SESSION"
    echo "System stays awake, display still sleeps | color=#6b7280 size=12"
else
    echo "MANUAL OVERRIDE"
fi

echo "30 minutes | sfimage=timer bash=\"$SCRIPT_PATH\" param1=start-30m terminal=false refresh=true"
echo "1 hour | sfimage=timer bash=\"$SCRIPT_PATH\" param1=start-1h terminal=false refresh=true"
echo "2 hours | sfimage=timer bash=\"$SCRIPT_PATH\" param1=start-2h terminal=false refresh=true"
echo "4 hours | sfimage=timer bash=\"$SCRIPT_PATH\" param1=start-4h terminal=false refresh=true"
echo "8 hours | sfimage=timer bash=\"$SCRIPT_PATH\" param1=start-8h terminal=false refresh=true"
echo "Indefinite | sfimage=infinity bash=\"$SCRIPT_PATH\" param1=start-indefinite terminal=false refresh=true"

echo "---"
echo "Force Away mode | sfimage=film bash=\"$SCRIPT_PATH\" param1=start-away terminal=false refresh=true"

echo "---"
echo "Refresh | sfimage=arrow.clockwise refresh=true"
