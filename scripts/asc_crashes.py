#!/usr/bin/env python3
"""Prints the TestFlight crash reports App Store Connect has for the app (newest first).

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, LIMIT (default 8).
Uses betaFeedbackCrashSubmissions (crashes testers shared from TestFlight) and their crash logs.
"""
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
import asc_enable_icloud as asc  # noqa: E402


def safe(method, path):
    try:
        return asc.call(method, path)
    except SystemExit as e:  # the helper exits on HTTP errors; keep going
        print(f"::warning::{e}")
        return {}


def main() -> int:
    bundle = os.environ.get("BUNDLE_ID", "com.fahad00x.lumen")
    limit = os.environ.get("LIMIT", "8")
    apps = safe("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle})).get("data", [])
    if not apps:
        print(f"::error::No App Store Connect app for {bundle}")
        return 1
    app_id = apps[0]["id"]
    subs = safe("GET", f"/apps/{app_id}/betaFeedbackCrashSubmissions?limit={limit}&sort=-createdDate").get("data", [])
    print(f"Crash submissions: {len(subs)}")
    for s in subs:
        a = s.get("attributes", {})
        print("=" * 100)
        print(f"{a.get('createdDate')}  {a.get('deviceModel')}  {a.get('osVersion')}  "
              f"build={a.get('buildBundleId', '')} comment={a.get('comment')!r}")
        log = safe("GET", f"/betaFeedbackCrashSubmissions/{s['id']}/crashLog").get("data", {})
        text = (log.get("attributes") or {}).get("logText") or ""
        print(text[:20000] if text else "(no crash log text)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
