# Sleep Guardian

> **Keep your Mac awake automatically when you leave home. Let it sleep normally when you're back.**

A [SwiftBar](https://swiftbar.app) menu bar plugin for macOS that automatically manages your Mac's sleep behavior based on whether you're home or away — using your **router's MAC address** as a silent, reliable location signal.

No GPS. No location services. No cloud. Just your local network.

**Solves:** Mac sleeping mid-upload, Dropbox pausing, long jobs dying, displays going dark on location — all without touching System Settings every time you leave the house.

---

## What It Does

### Away from home
The moment you leave your home network, Sleep Guardian **automatically blocks all sleep** — display and system — so your Mac keeps running for on-location shoots, remote work sessions, uploads, or anything that needs to stay alive.

### At home
When you're home, Sleep Guardian steps back and **lets your Mac sleep normally**. You're in control. If you need to keep it awake for a Dropbox sync, a long render, or anything else, you can start a manual session from the menu bar.

---

## How Location Detection Works — The MAC Address

A **MAC address** (Media Access Control address) is a unique hardware identifier burned permanently into your router at the factory. Think of it like a serial number for your router's network card. It:

- **Never changes** — it's hardware, not software
- **Is unique worldwide** — no two routers share the same MAC address
- **Never leaves your local network** — it's only visible to devices physically connected to your router

Sleep Guardian checks the MAC address of your default gateway (your router) every minute. If it matches the one you configured, you're home. If it doesn't — or if there's no match at all — you're away.

This is more reliable than checking SSIDs (Wi-Fi network names can be spoofed or duplicated), doesn't require internet access, and works on both Wi-Fi and ethernet.

### How to find your router's MAC address

Open Terminal and run:

```bash
arp -n $(route -n get default | awk '/gateway:/{print $2}') | awk '/:.+:.+:/{print $4}'
```

It will return something like `34:98:b5:d4:1b:37`. That's your home router's MAC address. Paste it into the `HOME_ROUTER_MAC` line at the top of the script.

---

## Menu Bar Modes

| Icon | Meaning |
|------|---------|
| 🏠 | Home — Mac sleeps normally |
| ☕ | Timed or indefinite stay-awake session active |
| 📷 | Away from home — full sleep block active automatically |

---

## Manual Sessions (available at home or away)

| Session | What it blocks |
|---------|---------------|
| 30 min / 1h / 2h / 4h / 8h | System sleep only — display still sleeps |
| Indefinite | System sleep only — display still sleeps |
| Force Away mode | Display **and** system sleep — identical to auto-away behavior |

For timed/indefinite sessions, `caffeinate -i -s -m` is used:
- `-i` — prevent idle sleep
- `-s` — prevent system sleep on AC power
- `-m` — prevent disk from sleeping (keeps network activity like Dropbox alive)

For away/full sessions, `caffeinate -d -i -m` is used (also blocks display sleep).

---

## macOS Sleep Settings

Sleep Guardian works *alongside* your macOS sleep settings, not instead of them. Here's how to configure them for best results:

### Recommended settings

1. Open **System Settings → Battery** (or **Energy Saver** on older macOS)
2. Set **"Turn display off after"** to whatever you like — Sleep Guardian won't fight this unless you start a Full session
3. Set **"Prevent automatic sleeping on power adapter when the display is off"** — toggle this **on** if you want Dropbox/syncs to run overnight without starting a manual session every time

### For MacBooks — prevent sleep on lid close (advanced)

If you close the lid and want your Mac to keep running (e.g., clamshell mode with an external display), that requires being plugged in and connected to an external display. Sleep Guardian cannot override lid-close sleep on its own — that's a hardware-level behavior.

### Power Nap

**System Settings → Battery → Options → Enable Power Nap** — when enabled, your Mac wakes briefly for iCloud/email syncs even during sleep. This is separate from Sleep Guardian and can be left on.

---

## Installation

1. Install [SwiftBar](https://swiftbar.app)
2. Copy `SleepGuardian.1m.sh` into your SwiftBar plugins folder
3. Make it executable:
   ```bash
   chmod +x ~/path/to/SleepGuardian.1m.sh
   ```
4. Find your router's MAC address (see above) and paste it into the `HOME_ROUTER_MAC` line at the top of the file
5. Refresh SwiftBar

The `1m` in the filename tells SwiftBar to re-run the script every **1 minute**, which is how the auto-detection stays current.

---

## Files Created at Runtime

| File | Purpose |
|------|---------|
| `~/.sleep-guardian-session` | Stores current session type and end time |
| `~/.sleep-guardian-caff.pid` | Stores the PID of the caffeinate process so it can be cleanly killed |

Both files are cleaned up automatically when a session ends.

---

## Requirements

- macOS (any recent version)
- [SwiftBar](https://swiftbar.app)
- No external dependencies — uses only built-in macOS tools (`caffeinate`, `arp`, `route`)
