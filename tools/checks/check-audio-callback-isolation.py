#!/usr/bin/env python3
"""Compile the production audio boundary with the app's actor settings.

Requires an existing iPhoneOS framework build (the script never builds, installs,
launches, or opens a microphone). Inspect SIL for the exact production callbacks,
optionally comparing a committed version that exhibited the device crash.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATHS = [
    "app/SpatialDemo/Conversation/AudioIOController.swift",
    "app/SpatialDemo/Conversation/PCMCodec.swift",
    "app/SpatialDemo/Conversation/ConversationModels.swift",
]
CURRENT_SOURCE_PATHS = SOURCE_PATHS + ["app/SpatialDemo/Conversation/RealtimeDependencies.swift"]
CALLBACKS = {
    "inputTap": "closure #1 in AudioIOController.installInputTap(input:)",
    "playbackCompletion": "closure #1 in AudioIOController.enqueuePlayback(_:itemID:contentIndex:)",
    "permissionCompletion": "closure #1 in closure #1 in static AudioIOController.requestMicrophonePermission()",
    "pcmConversion": ("MicrophonePCMEncoder.convert(_:gate:captureID:)", "MicrophonePCMEncoder.convert(_:)"),
}
PLAYBACK_UI_HOP = "closure #1 in closure #1 in AudioIOController.enqueuePlayback(_:itemID:contentIndex:)"


def inspect_function(sil, label):
    if isinstance(label, tuple):
        label = next(candidate for candidate in label if f"// {candidate}\n" in sil)
    start = sil.index(f"// {label}\n")
    end = sil.index("\n} // end sil function", start)
    body = sil[start:end]
    return {
        "isolation": body.splitlines()[1].removeprefix("// Isolation: "),
        "hasExecutorAssertion": "_checkExpectedExecutor" in body,
        "sendableEntry": "@convention(thin) @Sendable" in next(line for line in body.splitlines() if line.startswith("sil ")),
    }


def compile_and_inspect(source_paths, output, sdk, modules):
    command = [
        "xcrun", "swiftc", "-emit-silgen", "-whole-module-optimization", "-warnings-as-errors",
        "-swift-version", "6", "-default-isolation", "MainActor",
        "-enable-upcoming-feature", "InferIsolatedConformances",
        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-sdk", sdk, "-target", "arm64-apple-ios26.0", "-I", str(modules),
        "-module-cache-path", str(output.parent / "module-cache"),
        "-module-name", "AudioCallbackIsolation", *map(str, source_paths), "-o", str(output),
    ]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    output.with_suffix(".log").write_text(result.stdout + result.stderr)
    result.check_returncode()
    sil = output.read_text()
    return {
        "callbacks": {name: inspect_function(sil, label) for name, label in CALLBACKS.items()},
        "playbackUIHop": inspect_function(sil, PLAYBACK_UI_HOP),
        "silSha256": hashlib.sha256(output.read_bytes()).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modules", type=Path, default=ROOT / ".local/build/flow-device/Build/Products/Debug-iphoneos")
    parser.add_argument("--output", type=Path, default=ROOT / ".local/audio-callback-isolation")
    parser.add_argument("--before-ref", help="Optional committed audio source to verify the previous isolation trap")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    current = compile_and_inspect([ROOT / p for p in CURRENT_SOURCE_PATHS], args.output / "current.sil", sdk, args.modules)
    checks = {
        "allAudioEntriesNonisolated": all(item["isolation"] == "nonisolated" for item in current["callbacks"].values()),
        "noAudioEntryExecutorAssertion": all(not item["hasExecutorAssertion"] for item in current["callbacks"].values()),
        "sdkCallbacksExplicitlySendable": all(current["callbacks"][name]["sendableEntry"] for name in ["inputTap", "playbackCompletion", "permissionCompletion"]),
        "playbackUIHopRemainsMainActor": current["playbackUIHop"]["isolation"] == "global_actor. type: MainActor",
    }
    receipt = {
        "schema": "astra-audio-callback-isolation/v1", "sdk": sdk,
        "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
        "sources": [{"path": path, "sha256": hashlib.sha256((ROOT / path).read_bytes()).hexdigest()} for path in CURRENT_SOURCE_PATHS],
        "current": current, "checks": checks,
        "boundary": "Exact production-source SIL with iOS app actor settings. This verifies callback isolation and retained UI hop; it does not replace physical microphone/playback acceptance.",
    }
    if args.before_ref:
        before_directory = args.output / "before"
        before_directory.mkdir(exist_ok=True)
        before_sources = []
        for path in SOURCE_PATHS:
            copied = before_directory / Path(path).name
            copied.write_bytes(subprocess.check_output(["git", "show", f"{args.before_ref}:{path}"], cwd=ROOT))
            before_sources.append(copied)
        before = compile_and_inspect(before_sources, args.output / "before.sil", sdk, args.modules)
        receipt["beforeRef"] = subprocess.check_output(["git", "rev-parse", args.before_ref], cwd=ROOT, text=True).strip()
        receipt["before"] = before
        checks["beforeInputTapHasMainActorAssertion"] = before["callbacks"]["inputTap"]["isolation"] == "global_actor. type: MainActor" and before["callbacks"]["inputTap"]["hasExecutorAssertion"]
        checks["beforeEncoderWasMainActor"] = before["callbacks"]["pcmConversion"]["isolation"] == "global_actor. type: MainActor"
    receipt["status"] = "passed" if all(checks.values()) else "failed"
    destination = args.output / "receipt.json"
    destination.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "checks": checks, "receipt": str(destination)}, indent=2))
    raise SystemExit(0 if receipt["status"] == "passed" else 1)


if __name__ == "__main__":
    main()
