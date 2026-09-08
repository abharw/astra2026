#!/usr/bin/env python3
"""Probe the exact Flare Image API once; inject OPENAI_API_KEY through Doppler."""

import argparse
import base64
import binascii
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import struct
import time
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
ENDPOINT = "https://api.openai.com/v1/images/generations"
MODEL = "gpt-image-2.5-flare"
TIMEOUT_SECONDS = 150
MAX_RESPONSE_BYTES = 12 * 1024 * 1024
MAX_IMAGE_BYTES = 8 * 1024 * 1024
PROMPT = (
    "Create a clean educational diagram on a white background showing three blue "
    "rounded blocks labeled INPUT, PROCESS, OUTPUT, connected left to right by "
    "two blue arrows. Place no other words or objects."
)
BODY = {
    "model": MODEL,
    "prompt": PROMPT,
    "n": 1,
    "size": "1024x1024",
    "quality": "medium",
    "output_format": "png",
}


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def safe_text(value, key, limit=1000):
    if not isinstance(value, str):
        return None
    value = value.replace(key, "[redacted]")
    value = re.sub(r"sk-[A-Za-z0-9_-]+", "[redacted]", value)
    return "".join(character for character in value if character.isprintable())[:limit]


def read_bounded(response, maximum):
    chunks = []
    size = 0
    while True:
        chunk = response.read(min(64 * 1024, maximum - size + 1))
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        if size > maximum:
            raise ValueError("provider response exceeds byte limit")
        chunks.append(chunk)


def deadline_expired(_signum, _frame):
    raise TimeoutError("image probe exceeded its total deadline")


def png_dimensions(image):
    if len(image) < 33 or image[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("provider output is not a PNG")
    if image[8:16] != b"\x00\x00\x00\x0dIHDR":
        raise ValueError("provider PNG has no valid IHDR")
    width, height = struct.unpack(">II", image[16:24])
    if (width, height) != (1024, 1024):
        raise ValueError("provider dimensions differ from requested 1024x1024")
    return width, height


def usage_summary(value):
    if not isinstance(value, dict):
        return None
    result = {
        name: value[name]
        for name in ("input_tokens", "output_tokens", "total_tokens")
        if type(value.get(name)) is int and value[name] >= 0
    }
    details = value.get("input_tokens_details")
    if isinstance(details, dict):
        result["input_tokens_details"] = {
            name: details[name]
            for name in ("image_tokens", "text_tokens", "cached_tokens")
            if type(details.get(name)) is int and details[name] >= 0
        }
    return result


def persist_artifact(image, report):
    checksum = hashlib.sha256(image).hexdigest()
    directory = ROOT / ".local/illustration-probe"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{checksum}.png"
    try:
        with path.open("xb") as output:
            output.write(image)
    except FileExistsError:
        if path.read_bytes() != image:
            raise ValueError("immutable artifact checksum collision")
    width, height = png_dimensions(image)
    artifact = {
        "id": f"sha256:{checksum}",
        "sha256": checksum,
        "mimeType": "image/png",
        "width": width,
        "height": height,
        "bytes": len(image),
        "path": str(path.relative_to(ROOT)),
        "model": MODEL,
        "source": "fixed API access probe; not live scene context",
    }
    metadata_path = directory / f"{checksum}.json"
    if not metadata_path.exists():
        metadata_path.write_text(json.dumps({**report, "artifact": artifact}, indent=2) + "\n")
    return artifact


def probe(key):
    body = json.dumps(BODY).encode("utf-8")
    if len(body) > 4096:
        raise ValueError("probe input exceeds 4 KiB")
    report = {
        "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "probe": "exact-model direct Image API generation",
        "endpoint": ENDPOINT,
        "request": BODY,
        "timeoutSeconds": TIMEOUT_SECONDS,
        "maximumResponseBytes": MAX_RESPONSE_BYTES,
        "maximumImageBytes": MAX_IMAGE_BYTES,
        "fallbackUsed": False,
        "attempts": 1,
    }
    started = time.monotonic()
    request = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    opener = urllib.request.build_opener(NoRedirects)
    previous_handler = signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, TIMEOUT_SECONDS)
    try:
        try:
            response = opener.open(request, timeout=TIMEOUT_SECONDS)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            report["httpStatus"] = response.status
            report["requestId"] = safe_text(response.headers.get("x-request-id"), key, 128)
            raw = read_bounded(response, MAX_RESPONSE_BYTES if response.status == 200 else 16 * 1024)
        report["responseBytes"] = len(raw)
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("provider response is not an object")
        if report["httpStatus"] != 200:
            error = payload.get("error")
            if not isinstance(error, dict):
                error = {}
            report["outcome"] = "provider_rejected"
            report["error"] = {
                "code": safe_text(error.get("code"), key, 128),
                "type": safe_text(error.get("type"), key, 128),
                "message": safe_text(error.get("message"), key),
            }
            return report
        data = payload.get("data")
        if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
            raise ValueError("provider did not return exactly one completed image")
        encoded = data[0].get("b64_json")
        if not isinstance(encoded, str) or len(encoded) > 4 * ((MAX_IMAGE_BYTES + 2) // 3):
            raise ValueError("provider image is missing or exceeds byte limit")
        image = base64.b64decode(encoded, validate=True)
        if len(image) > MAX_IMAGE_BYTES:
            raise ValueError("decoded image exceeds byte limit")
        png_dimensions(image)
        report["outcome"] = "generated"
        report["usage"] = usage_summary(payload.get("usage"))
        report["elapsedMs"] = round((time.monotonic() - started) * 1000)
        report["artifact"] = persist_artifact(image, report)
    except (urllib.error.URLError, TimeoutError, ValueError, binascii.Error, OSError) as error:
        report["outcome"] = "probe_failed"
        # Exception text may contain provider data; keep only its classification.
        report["failureType"] = type(error).__name__
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        report["elapsedMs"] = round((time.monotonic() - started) * 1000)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report", type=Path, default=ROOT / ".local/illustration-probe/access.json",
        help="Write a redacted JSON receipt here (default: .local/illustration-probe/access.json).",
    )
    args = parser.parse_args()
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        parser.error("OPENAI_API_KEY is missing; inject it through Doppler.")
    report = probe(key)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["outcome"] == "generated" else 1


if __name__ == "__main__":
    raise SystemExit(main())
