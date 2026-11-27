# PresenceBar

A small macOS menu bar app that tells who is home, from the family phones
connected to a TP-Link Archer Wi-Fi router. It only reports presence; it
controls nothing. Other apps on the same Mac can read the result through a
local HTTP API.

## How it works

Every 10 minutes (and within a minute of the Mac waking up) PresenceBar reads
the router's list of connected devices:

- a person is **home** when their phone is connected at that check, **away**
  when it is not (no grace period);
- the **house** is home while anyone is;
- when the router can't be read, every state is kept as it was.

The panel shows the house state, one line per person (with when their phone
was last seen), the latest changes ("Bob left", "Alice came home"), and
phone-like devices that are not in the configuration yet.

## API

PresenceBar listens on `127.0.0.1:8787` only, so nothing outside the Mac can
reach it.

```bash
curl http://127.0.0.1:8787/presence
curl "http://127.0.0.1:8787/events?limit=5"
```

`/presence`:

```json
{
  "state": "home",
  "since": 1795710360,
  "checked_at": 1795765044,
  "router_ok": true,
  "home": ["Alice"],
  "people": [
    {"who": "Alice", "home": true,  "since": 1795710360, "last_seen": 1795765044},
    {"who": "Bob",   "home": false, "since": 1795765044, "last_seen": 1795763715}
  ]
}
```

Times are Unix timestamps in seconds. The data is only as fresh as the last
check: compare `checked_at` with the current time, since the Mac may have
slept or PresenceBar may be paused.

`/events` returns the latest changes, newest first:
`{"time", "who", "event", "last_seen"}`, where `who` is a person or `house`
and `event` is `home` or `away`.

## Files

PresenceBar keeps its data in `~/Projects/netatmo`:

| File | Content |
|---|---|
| `presence-state.json` | current state (what `/presence` returns) |
| `presence-events.csv` | one row per change |
| `presence-log.csv` | one row per check |
| `presence-phones-seen.json` | last time each device was seen |

## Requirements

- macOS 14 or later, Swift command-line tools (no Xcode project needed).
- `~/Projects/netatmo/archer_presence.py`: a small read-only helper that signs
  in to the router with [tplinkrouterc6u](https://github.com/AlexandrErohin/TP-Link-Archer-C6U),
  prints the connected devices as JSON and signs out. It runs from the
  virtual environment `~/Projects/netatmo/.venv-tplink`. The router allows a
  single admin session, so each check may sign you out of the router's web
  page.
- `~/.config/netatmo/phones.json` (keep it `chmod 600`):

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

## Build

```bash
./build.sh         # builds build/PresenceBar.app
./build.sh --run   # builds and (re)launches it
```
