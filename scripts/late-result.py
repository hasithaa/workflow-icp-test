#!/usr/bin/env python3
"""Posts a command result to the ICP as a runtime would, for the late-result case.

The bridge signs its calls with an HS256 JWT whose key is the org secret's key material and
whose kid is the part before the dot (see the bridge's security.bal). Reproducing that here is
what makes this test end-to-end rather than a SQL simulation: the result travels the real
/icp/commandResult path, with real auth, and the ICP's fencing has to reject it on its merits.

Usage: late-result.py <runtimeId> <commandId> <httpStatus> <bodyJson>
"""
import base64
import hashlib
import hmac
import json
import os
import ssl
import sys
import time
import urllib.request


def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def mint(secret: str) -> str:
    key_id, _, key_material = secret.partition(".")
    if not key_material:  # a secret with no kid, which the bridge also allows
        key_id, key_material = "", secret
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT", "kid": key_id}
    claims = {
        "iss": os.environ.get("JWT_ISSUER", "icp-runtime-jwt-issuer"),
        "aud": os.environ.get("JWT_AUDIENCE", "icp-server"),
        "scope": "runtime_agent",
        "iat": now,
        "nbf": now,
        "exp": now + 300,
    }
    signing_input = f"{b64u(json.dumps(header).encode())}.{b64u(json.dumps(claims).encode())}"
    sig = hmac.new(key_material.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64u(sig)}"


def main() -> int:
    runtime_id, command_id, http_status, body = sys.argv[1:5]
    secret = os.environ["ICP_ORG_SECRET"]
    base = os.environ.get("ICP_RUNTIME_URL", "https://localhost:9445")

    payload = {
        "runtimeId": runtime_id,
        "commandId": command_id,
        "status": "COMPLETED",
        "httpStatus": int(http_status),
        "body": json.loads(body),
    }
    request = urllib.request.Request(
        f"{base}/icp/commandResult",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {mint(secret)}"},
        method="POST",
    )
    # Self-signed all the way through this environment, at the edge and at the nodes.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(request, context=ctx, timeout=30) as response:
            print(f"{response.status} {response.read(200).decode(errors='replace')}")
    except urllib.error.HTTPError as e:
        print(f"{e.code} {e.read(200).decode(errors='replace')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
