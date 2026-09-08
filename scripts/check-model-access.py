#!/usr/bin/env python3
"""Small live API access probe. Inject only OPENAI_API_KEY using Doppler."""
import datetime
import json
import os
from pathlib import Path
import urllib.error
import urllib.request


def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/" + path,
        data=data,
        headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"],
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        payload = json.loads(error.read())
        # Record error classification, never raw headers, credentials, or messages.
        return error.code, {"error": {"code": payload.get("error", {}).get("code"),
                                    "type": payload.get("error", {}).get("type")}}


def main():
    if not os.environ.get("OPENAI_API_KEY"):
        raise SystemExit("OPENAI_API_KEY is missing; run through Doppler.")
    report = {"checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "models": []}
    for model in ["gpt-6-astra", "gpt-realtime-2.1"]:
        status, payload = request("models/" + model)
        report["models"].append({"model": model, "httpStatus": status,
                                 "returnedModel": payload.get("id"), "error": payload.get("error")})
    if report["models"][0]["httpStatus"] == 200:
        status, payload = request("responses", {
            "model": "gpt-6-astra", "input": "Reply with exactly OK.",
            "max_output_tokens": 128, "reasoning": {"effort": "low"}, "store": False,
        })
        output = "".join(part.get("text", "") for item in payload.get("output", [])
                         for part in item.get("content", []) if part.get("type") == "output_text")
        report["astraProbe"] = {"httpStatus": status, "responseId": payload.get("id"),
                                "status": payload.get("status"), "reply": output,
                                "usage": payload.get("usage"), "error": payload.get("error")}
    path = Path(__file__).resolve().parents[1] / "evidence/local/model-access.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
