#!/usr/bin/env python3
"""Waits for App Store Connect to finish processing a build and reports its state.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, BUILD_NUMBER, PLATFORM (IOS|TV_OS),
     WAIT_MINUTES (default 45).
Exit 0 when the build is VALID, 1 when it is INVALID (rejected in processing, e.g. ITMS-90208)
or still not processed in time.
"""
import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
from asc_enable_icloud import call  # noqa: E402  (JWT-signed App Store Connect API call)


def main() -> int:
    bundle = os.environ.get("BUNDLE_ID", "com.fahad00x.lumen")
    number = os.environ["BUILD_NUMBER"]
    platform = os.environ.get("PLATFORM", "TV_OS")
    deadline = time.time() + 60 * int(os.environ.get("WAIT_MINUTES", "45"))

    apps = call("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle})).get("data", [])
    if not apps:
        print(f"::error::No App Store Connect app for {bundle}")
        return 1
    app_id = apps[0]["id"]

    query = urllib.parse.urlencode({
        "filter[app]": app_id,
        "filter[version]": number,
        "filter[preReleaseVersion.platform]": platform,
        "fields[builds]": "version,processingState,uploadedDate,expired,minOsVersion",
        "limit": "5",
    })
    state = None
    while time.time() < deadline:
        builds = call("GET", f"/builds?{query}").get("data", [])
        if builds:
            a = builds[0]["attributes"]
            state = a.get("processingState")
            print(f"{platform} build {a.get('version')}: {state} (uploaded {a.get('uploadedDate')}, minOS {a.get('minOsVersion')})")
            if state == "VALID":
                return 0
            if state in ("INVALID", "FAILED"):
                print(f"::error::App Store Connect rejected {platform} build {number} during processing "
                      f"({state}). Apple's email lists the ITMS codes.")
                return 1
        else:
            print(f"{platform} build {number}: not visible yet")
        time.sleep(60)
    print(f"::error::{platform} build {number} still {state or 'not visible'} after waiting")
    return 1


if __name__ == "__main__":
    sys.exit(main())
