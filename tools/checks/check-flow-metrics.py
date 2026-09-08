#!/usr/bin/env python3
"""Run the explicit Debug flow fixture and summarize native CPU/cadence receipts.

Requires an installed Debug app. This restarts that app for each requested count.
It uses existing saved endpoint settings and never reads or prints credentials.
Simulator observations never establish physical AR or GPU performance.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
APP_ID = "com.astra.spatialdemo"
ALLOWED_COUNTS = {0, 1, 8, 32}


def command(arguments, *, environment=None, timeout=45):
    result = subprocess.run(arguments, env=environment, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # These commands contain no credentials. Preserve the actual device lock
        # or installation error so the receipt cannot mislabel it as acceptance.
        raise RuntimeError((result.stderr or result.stdout)[-3000:].strip())
    return result.stdout


def collect_diagnostics(target, simulator, destination):
    if simulator:
        container = command(["xcrun", "simctl", "get_app_container", target, APP_ID, "data"]).strip()
        source = Path(container) / "Documents" / "AstraDiagnostics"
        shutil.copytree(source, destination)
    else:
        command(["xcrun", "devicectl", "device", "copy", "from", "--device", target,
                 "--domain-type", "appDataContainer", "--domain-identifier", APP_ID,
                 "--source", "Documents/AstraDiagnostics", "--destination", str(destination), "--timeout", "30"])


def decode_fields(fields):
    result = {}
    for key, value in fields.items():
        if value in ("true", "false"):
            result[key] = value == "true"
            continue
        try:
            number = float(value)
            if not math.isfinite(number):
                raise ValueError("Nonfinite metric")
            result[key] = int(number) if number.is_integer() else number
        except (TypeError, ValueError):
            result[key] = value
    return result


def summarize(directory, count, after, expected_surface):
    events = []
    sources = []
    for path in sorted(directory.rglob("*.jsonl")):
        data = path.read_bytes()
        sources.append({"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest()})
        for line in data.splitlines():
            try:
                event = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue
            if event.get("component") == "app.flow_acceptance" and event.get("timestamp", "") >= after:
                events.append(event)
    starts = [event for event in events if event.get("event") == "flow.acceptance.started"
              and str(event.get("fields", {}).get("requestedFlowCount")) == str(count)]
    if not starts:
        raise RuntimeError("No matching Debug acceptance start; confirm build and active unlocked app.")
    start = starts[-1]
    correlation = start.get("correlationID")
    selected = [event for event in events if event.get("correlationID") == correlation]
    samples = [decode_fields(event.get("fields", {})) for event in selected
               if event.get("event") == "flow.acceptance.sample"]
    finished = [event for event in selected if event.get("event") == "flow.acceptance.finished"]
    checks = {
        "completed": bool(finished),
        "thirtySamples": len(samples) == 30,
        "orderedSamples": [sample.get("sampleIndex") for sample in samples] == list(range(1, 31)),
        "thirtySecondsObserved": bool(samples) and samples[-1].get("elapsedSeconds", 0) >= 29.5,
        "surfaceMatchesTarget": all(sample.get("surface") == expected_surface for sample in samples),
        "requestedFlowCount": all(sample.get("flowCount") == count for sample in samples),
        "boundedMarkers": all(isinstance(sample.get("markerCount"), int)
                              and 0 <= sample["markerCount"] <= count * 4 for sample in samples),
        "boundedTimingRing": all(isinstance(sample.get("sampleCount"), int)
                                 and 0 < sample["sampleCount"] <= 300 for sample in samples),
        "noMeshRebuildDuringAnimation": bool(samples) and len({sample.get("meshRebuildCount") for sample in samples}) == 1,
        "callbacksAdvanced": len(samples) > 1 and samples[-1].get("updateCount", 0) > samples[0].get("updateCount", 0),
        "boundedUniqueResources": all(0 <= sample.get("meshCount", -1) <= (count * 2 + 2 if count else 0)
                                      and 0 <= sample.get("vertexCount", -1) <= 500_000
                                      and 0 <= sample.get("triangleCount", -1) <= 250_000 for sample in samples),
        "finiteTiming": all(isinstance(sample.get(key), (float, int)) and math.isfinite(sample[key]) and sample[key] >= 0
                            for sample in samples for key in ("meanFrameIntervalMs", "p95FrameIntervalMs", "meanMarkerUpdateMs", "p95MarkerUpdateMs", "maximumMarkerUpdateMs")),
    }
    return {
        "requestedFlowCount": count, "status": "passed" if all(checks.values()) else "failed",
        "correlationID": correlation, "checks": checks, "samples": samples,
        "environment": decode_fields(start.get("fields", {})),
        "finalFields": decode_fields(finished[-1].get("fields", {})) if finished else None,
        "sources": sources,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--simulator-id")
    target.add_argument("--device")
    parser.add_argument("--counts", default="0,1,8,32", help="Comma-separated subset of 0,1,8,32")
    parser.add_argument("--out", required=True, help="New output directory beneath .local/")
    args = parser.parse_args()
    try:
        counts = list(dict.fromkeys(int(value) for value in args.counts.split(",")))
    except ValueError:
        parser.error("Counts must be a nonempty subset of 0,1,8,32")
    if not counts or not set(counts) <= ALLOWED_COUNTS:
        parser.error("Counts must be a nonempty subset of 0,1,8,32")
    output = (ROOT / args.out).resolve()
    if not output.is_relative_to(ROOT / ".local") or output == ROOT / ".local" or output.exists():
        parser.error("Use a new output directory beneath .local/")
    output.mkdir(parents=True)
    simulator = args.simulator_id is not None
    target_id = args.simulator_id or args.device
    report = {"schema": "astra-native-flow-metrics/v1", "startedAt": datetime.now(timezone.utc).isoformat(),
              "surface": "simulator" if simulator else "physicalAR", "status": "running", "runs": [],
              "boundary": "Explicit synthetic Debug fixture. CPU marker-loop wall time and SceneEvents.Update cadence; no GPU-time, thermal-soak, pointing, or visual-fidelity claim."}
    try:
        for count in counts:
            after = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            environment = os.environ.copy()
            prefix = "SIMCTL_CHILD_" if simulator else "DEVICECTL_CHILD_"
            environment[prefix + "ASTRA_FLOW_ACCEPTANCE_COUNT"] = str(count)
            if simulator:
                launch = ["xcrun", "simctl", "launch", "--terminate-running-process", target_id, APP_ID]
            else:
                launch = ["xcrun", "devicectl", "device", "process", "launch", "--device", target_id,
                          "--terminate-existing", APP_ID]
            command(launch, environment=environment)
            print(json.dumps({"event": "sampling", "flowCount": count, "surface": report["surface"]}), flush=True)
            # The app owns thirty active-window samples; this host wait allows
            # startup without presenting host sleeps as measured frame time.
            time.sleep(36)
            destination = output / f"count-{count}"
            collect_diagnostics(target_id, simulator, destination)
            run = summarize(destination, count, after, report["surface"])
            report["runs"].append(run)
            print(json.dumps({"event": "measured", "flowCount": count, "status": run["status"], "checks": run["checks"]}), flush=True)
            if run["status"] != "passed":
                raise RuntimeError(f"Native acceptance checks failed for {count} flows")
        report["status"] = "passed"
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["status"] = "failed"
        report["error"] = str(error)[:3000]
    finally:
        (output / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "receipt": str((output / "receipt.json").relative_to(ROOT))}), flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
