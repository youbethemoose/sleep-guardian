#!/bin/bash

# <bitbar.title>Sleep Guardian</bitbar.title>
# <bitbar.version>3.0</bitbar.version>
# <bitbar.author>Robby Mueller</bitbar.author>
# <bitbar.desc>Auto keep-awake based on home network. Timed sessions when home.</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>

# ════════════════════════════════════════════════
#  CONFIGURE THIS — your home router's MAC address
#  This is burned into your physical router hardware.
#  It never changes and is unique in the world.
#  To find it: arp -n 192.168.1.1 | awk '{print $4}'
# ════════════════════════════════════════════════
HOME_ROUTER_MAC="34:98:b5:d4:1b:37"

# ════════════════════════════════════════════════
#  Internal — do not edit below this line
# ════════════════════════════════════════════════
SESSION_FILE="/Users/robbymueller/.sleep-guardian-session"
CAFFEINATE_PID_FILE="/Users/robbymueller/.sleep-guardian-caff.pid"
SCRIPT_PATH="$0"

# ── Helpers ─────────────────────────────────────

# Gets the MAC address of the default gateway (your router),
# works on WiFi and ethernet, needs no special permissions.
# We ping first to ensure the ARP table is populated,
# then read from it — all local, no internet required.
get_router_mac() {
    # Find the default gateway IP across any interface
    local gateway
    gateway=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    [ -z "$gateway" ] && echo "" && return

    # Ping once silently to populate ARP cache (instant, local only)
    ping -c 1 -W 1 "$gateway" &>/dev/null

    # Read MAC from ARP table
    arp -n "$gateway" 2>/dev/null | awk '/:.+:.+:/{print $4}' | head -1
}

is_home_network() {
    local mac
    mac=$(get_router_mac)
    [ "$mac" = "$HOME_ROUTER_MAC" ] && return 0
    return 1
}

read_session() {
    [ -f "$SESSION_FILE" ] && cat "$SESSION_FILE" || echo ""
}

kill_caffeinate() {
    if [ -f "$CAFFEINATE_PID_FILE" ]; then
        local pid
        pid=$(cat "$CAFFEINATE_PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$CAFFEINATE_PID_FILE"
    fi
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

# Check if caffeinate is still alive
CAFF_RUNNING=false
if [ -f "$CAFFEINATE_PID_FILE" ]; then
    pid=$(cat "$CAFFEINATE_PID_FILE")
    kill -0 "$pid" 2>/dev/null && CAFF_RUNNING=true
fi

# Detect home vs away (the reliable way)
is_home_network && AT_HOME=true || AT_HOME=false

# Auto-start full block when away and no session running
if ! $AT_HOME && [ -z "$SESSION_TYPE" ]; then
    action_start_away
    SESSION_TYPE="away"
fi

# Auto-end away session the moment you get home
if $AT_HOME && [ "$SESSION_TYPE" = "away" ]; then
    action_stop
    SESSION_TYPE=""
fi

# Revive caffeinate if it died unexpectedly
if [ -n "$SESSION_TYPE" ] && ! $CAFF_RUNNING; then
    [ "$SESSION_TYPE" = "away" ] && start_caffeinate "full" || start_caffeinate "system"
fi

# ── Menubar title (emoji only) ───────────────────
if [ "$SESSION_TYPE" = "away" ]; then
    echo "📷"
elif [ "$SESSION_TYPE" = "timed" ]; then
    echo "☕"
elif [ "$SESSION_TYPE" = "indefinite" ]; then
    echo "☕"
else
    $AT_HOME && echo "🏠" || echo "📷"
fi

echo "---"

# ── Dropdown ─────────────────────────────────────

$AT_HOME && echo "📍 Home network detected" || echo "📍 Away from home"

if [ "$SESSION_TYPE" = "away" ]; then
    echo "⚡ Away session active"
    echo "   Display + system sleep: BLOCKED | color=#fbbf24"
elif [ "$SESSION_TYPE" = "timed" ]; then
    echo "⏱ Timed session — $(format_remaining "$SESSION_ENDS") remaining"
    echo "   System sleep: BLOCKED  /  Display: sleeps normally | color=#fbbf24"
elif [ "$SESSION_TYPE" = "indefinite" ]; then
    echo "∞ Indefinite session active"
    echo "   System sleep: BLOCKED  /  Display: sleeps normally | color=#fbbf24"
else
    echo "💤 No session — Mac sleeps normally | color=#6b7280"
fi

echo "---"

if [ -n "$SESSION_TYPE" ]; then
    echo "⏹ End Session | bash=$SCRIPT_PATH param1=stop terminal=false refresh=true"
    echo "---"
fi

if $AT_HOME; then
    echo "START TIMED SESSION"
    echo "   System stays awake, display still sleeps | color=#6b7280"
else
    echo "MANUAL OVERRIDE"
fi

echo "⏱ 30 minutes   | bash=$SCRIPT_PATH param1=start-30m terminal=false refresh=true"
echo "⏱ 1 hour       | bash=$SCRIPT_PATH param1=start-1h  terminal=false refresh=true"
echo "⏱ 2 hours      | bash=$SCRIPT_PATH param1=start-2h  terminal=false refresh=true"
echo "⏱ 4 hours      | bash=$SCRIPT_PATH param1=start-4h  terminal=false refresh=true"
echo "⏱ 8 hours      | bash=$SCRIPT_PATH param1=start-8h  terminal=false refresh=true"
echo "∞ Indefinite    | bash=$SCRIPT_PATH param1=start-indefinite terminal=false refresh=true"

echo "---"
echo "🎬 Force Away mode | bash=$SCRIPT_PATH param1=start-away terminal=false refresh=true"

echo "---"
echo "🔄 Refresh | refresh=true"