#!/usr/bin/env python3
"""Lists the account's signing certificates (read only: nothing is revoked or created).

The repository is public, so its run logs are too: names (which can carry a person's or a
Mac's name) are not printed. Each certificate shows its type, platform, expiry date and the
last 4 characters of its serial number, enough to find it on developer.apple.com →
Certificates. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
"""
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(__file__))
from asc_enable_icloud import call  # noqa: E402  (JWT-signed App Store Connect API call)


def main() -> int:
    fields = "certificateType,platform,expirationDate,serialNumber"
    certs = call("GET", f"/certificates?fields[certificates]={fields}&limit=200").get("data", [])
    now = datetime.now(timezone.utc)
    rows = []
    for c in certs:
        a = c.get("attributes", {})
        expires = a.get("expirationDate") or ""
        try:
            days = (datetime.fromisoformat(expires.replace("Z", "+00:00")) - now).days
        except ValueError:
            days = None
        rows.append((a.get("certificateType") or "?", a.get("platform") or "-", expires[:10],
                     days, (a.get("serialNumber") or "")[-4:]))
    rows.sort(key=lambda r: (r[0], r[2]))
    print(f"Certificates: {len(rows)}")
    print(f"{'type':<28} {'platform':<10} {'expires':<12} {'days left':>9}  serial(last 4)")
    for kind, platform, expires, days, serial in rows:
        print(f"{kind:<28} {platform:<10} {expires:<12} {'' if days is None else days:>9}  …{serial}")
    counts = {}
    for r in rows:
        counts[r[0]] = counts.get(r[0], 0) + 1
    print("Per type: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
