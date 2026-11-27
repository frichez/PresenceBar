#!/usr/bin/env python3
"""READ-ONLY helper for PresenceBar: print the Archer's connected devices as JSON.

Signs in, reads the device list, always signs out (the router allows one admin
session). Changes no router setting. Output on stdout, one JSON object:
  {"ok": true, "devices": [{"mac", "name", "ip", "band", "private"}]}
  {"ok": false, "error": "..."}
Run with the private environment:  .venv-tplink/bin/python -I archer_presence.py
"""
import json, os, sys, warnings

CRED = os.path.expanduser("~/.config/tplink/archer.json")


def main():
    try:
        from tplinkrouterc6u import TplinkRouterProvider
        c = json.load(open(CRED))
        warnings.filterwarnings("ignore")  # self-signed router certificate
        router = TplinkRouterProvider.get_client(c["host"], c["password"], c.get("username", "admin"),
                                                 verify_ssl=False, timeout=20)
        router.authorize()
        try:
            status = router.get_status()
        finally:
            router.logout()
        out = []
        for d in status.devices:
            mac = str(d.macaddr).replace("-", ":").lower()
            out.append({"mac": mac, "name": d.hostname or "", "ip": str(d.ipaddr or ""),
                        "band": str(d.type).split(".")[-1], "private": int(mac.split(":")[0], 16) & 2 != 0})
        print(json.dumps({"ok": True, "devices": out}))
    except Exception as e:  # report, never crash the caller
        print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"[:200]}))


if __name__ == "__main__":
    main()
