#!/usr/bin/env python3
"""Turns on the iCloud capability (CloudKit, Xcode 6+) for the app's Bundle ID through the
App Store Connect API, so the signing step can create a profile with iCloud.

The API cannot create an iCloud container or assign it to the Bundle ID: that part is done
once on developer.apple.com (see SETUP-TESTFLIGHT.md). The script says whether it's needed.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID. Standard library + openssl only.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig: bytes) -> bytes:
    """ECDSA DER signature (SEQUENCE { INTEGER r, INTEGER s }) -> r || s, 32 bytes each."""
    def read_len(buf, i):
        n = buf[i]
        i += 1
        if n & 0x80:
            count = n & 0x7F
            n = int.from_bytes(buf[i:i + count], "big")
            i += count
        return n, i

    assert sig[0] == 0x30
    _, i = read_len(sig, 1)
    out = b""
    for _ in range(2):
        assert sig[i] == 0x02
        n, i = read_len(sig, i + 1)
        value = sig[i:i + n].lstrip(b"\x00")
        out += value.rjust(32, b"\x00")
        i += n
    return out


def token() -> str:
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64url(der_to_raw(der))}"


def call(method: str, path: str, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise SystemExit(f"App Store Connect API {method} {path} failed ({e.code}): {detail}")


def main() -> int:
    bundle = os.environ.get("BUNDLE_ID", "com.fahad00x.lumen")
    query = urllib.parse.urlencode({"filter[identifier]": bundle, "limit": "50"})
    ids = [d for d in call("GET", f"/bundleIds?{query}").get("data", [])
           if d["attributes"]["identifier"] == bundle]
    if not ids:
        print(f"::warning::Bundle ID {bundle} is not registered (see SETUP-TESTFLIGHT.md, step 2).")
        return 0
    bundle_id = ids[0]["id"]

    caps = call("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities").get("data", [])
    if any(c["attributes"].get("capabilityType") == "ICLOUD" for c in caps):
        print("iCloud capability is already enabled for", bundle)
    else:
        call("POST", "/bundleIdCapabilities", {
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {
                    "capabilityType": "ICLOUD",
                    "settings": [{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6"}]}],
                },
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}},
            }
        })
        print("Enabled the iCloud capability (CloudKit) for", bundle)

    # tvOS apps that use CloudKit must also carry the push entitlement (aps-environment).
    caps = call("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities").get("data", [])
    if any(c["attributes"].get("capabilityType") == "PUSH_NOTIFICATIONS" for c in caps):
        print("Push Notifications capability is already enabled for", bundle)
    else:
        call("POST", "/bundleIdCapabilities", {
            "data": {
                "type": "bundleIdCapabilities",
                "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}},
            }
        })
        print("Enabled the Push Notifications capability for", bundle)

    print("Note: the API can't create or assign iCloud containers. If the upload fails with an "
          "iCloud / container error, create iCloud.com.fahad00x.lumen and assign it to the Bundle ID "
          "once on developer.apple.com (SETUP-TESTFLIGHT.md, step 2b).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
