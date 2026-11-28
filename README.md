# PresenceBar

A small macOS menu bar app that tells who is home, from the family phones
connected to a TP-Link Archer Wi-Fi router. It only reports presence; it
controls nothing. Other apps on the same Mac can read the result through
AppLink, a small API over distributed notifications.

## How it works

Every 5 minutes (and within a minute of the Mac waking up) PresenceBar reads
the router's list of connected devices:

- a person is **home** when their phone is connected at that check, **away**
  when it is not (no grace period);
- the **house** is home while anyone is;
- when the router can't be read, every state is kept as it was.

The panel shows the house state, one line per person (with when their phone
was last seen), the latest changes ("Bob left", "Alice came home"), and
phone-like devices that are not in the configuration yet.

## API

Other apps on this Mac read PresenceBar through AppLink (`Sources/AppLink.swift`): distributed notifications,
no port and no server. It replaced the earlier HTTP service on `127.0.0.1:8787`. The protocol and the other
apps' APIs are described in AlexaBridge's README (`~/Projects/AlexaBridge`).

```bash
A=~/Projects/AlexaBridge/build/AlexaBridge.app/Contents/MacOS/AlexaBridge
$A get PresenceBar
```

`get PresenceBar` answers the last check (presence-state.json) plus `paused`:

```json
{
  "api": 1,
  "state": "home",
  "since": 1795710360,
  "checked_at": 1795765044,
  "router_ok": true,
  "paused": false,
  "home": ["Alice"],
  "people": [
    {"who": "Alice", "home": true,  "since": 1795710360, "last_seen": 1795765044},
    {"who": "Bob",   "home": false, "since": 1795765044, "last_seen": 1795763715}
  ]
}
```

When the router can't be read, `router_ok` is `false` and `router_error`
says why. Times are Unix timestamps in seconds. The data is only as fresh as the last
check: compare `checked_at` with the current time, since the Mac may have
slept or PresenceBar may be paused.

With `{"events": 20}` as arguments, the answer also has `events`: the latest changes, newest first,
`{"time", "who", "event", "last_seen"}`, where `who` is a person or `house` and `event` is `home` or `away`.
PresenceBar has no actions: it reports, it controls nothing.

## Files

PresenceBar keeps its history in `data/` next to the sources. The folder is
gitignored, so it never leaves the Mac:

| File | Content |
|---|---|
| `presence-state.json` | current state (what `get PresenceBar` returns) |
| `presence-events.csv` | one row per change |
| `presence-log.csv` | one row per check |
| `presence-phones-seen.json` | last time each device was seen |

Nothing in `data/` is ever trimmed or rotated, so the history is kept forever.
At one check every 5 minutes, `presence-log.csv` grows by about 4 MB a year.
Because the folder is gitignored, back it up yourself (Time Machine covers it).

## Requirements

- macOS 14 or later, Swift command-line tools (no Xcode project needed).
- A TP-Link router that uses the "SG" sign-in (SHA-256, RSA-OAEP and
  HMAC-SHA256, e.g. Archer BE550 or BE3600). [`RouterClient.swift`](Sources/RouterClient.swift)
  is a Swift port of that part of [tplinkrouterc6u](https://github.com/AlexandrErohin/TP-Link-Archer-C6U):
  it signs in, reads the connected devices and signs out. It changes no
  router setting, and needs no Python or other packages. The router allows a
  single admin session, so a check may sign you out of the router's web page.
- `~/.config/tplink/archer.json`, the router login (keep it `chmod 600`):

```json
{"host": "https://192.168.0.1", "username": "admin", "password": "your-router-password"}
```

- `~/.config/tplink/phones.json` (keep it `chmod 600`):

```json
{
  "phones": [
    {"who": "Alice", "router_name": "iPhone", "mac": "aa:bb:cc:dd:ee:01"},
    {"who": "Bob",   "router_name": "iPhone", "mac": "aa:bb:cc:dd:ee:02"}
  ],
  "not_phones": {
    "aa:bb:cc:dd:ee:10": "iPad (stays home)"
  }
}
```

On each iPhone, set **Private Wi-Fi Address** to **Fixed** for the home
network, so its address doesn't change.

On first launch macOS asks to let PresenceBar access the **local network**:
allow it. Without it every check fails with "The Internet connection appears
to be offline" (System Settings > Privacy & Security > Local Network).

## Build

The history folder assumes the repo is cloned to `~/Projects/PresenceBar`
(see `Detector.repo`).

```bash
./build.sh         # builds build/PresenceBar.app
./build.sh --run   # builds and (re)launches it
```

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). `Sources/RouterClient.swift` is a
port of part of [tplinkrouterc6u](https://github.com/AlexandrErohin/TP-Link-Archer-C6U),
which is licensed under GPL-3.0-or-later.

When the menu bar icon is hidden (behind the notch on the laptop screen), open PresenceBar again from Spotlight or Finder while it runs: its panel then opens in a normal window.

## Alexa (optional)

When AlexaBridge (`~/Projects/AlexaBridge`) runs, "Alexa, qui est à la maison" is answered from `get PresenceBar`.
All the voice handling is in AlexaBridge; PresenceBar knows nothing about it.
