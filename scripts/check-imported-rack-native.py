#!/usr/bin/env python3
"""Run real USDZ native acceptance tests and record local import timings.

Usage: python3 scripts/check-imported-rack-native.py [--variant conservative]
Requires the pinned source/derived USDZ files named in the validation catalogs.
This does not download assets, attach an ARView, or measure GPU frame rate.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", action="append", choices=["source", "conservative", "distance"])
    parser.add_argument("--output", type=Path, default=root / "evidence/imported-rack-native.json")
    args = parser.parse_args()
    manifest_path = root / "examples/imported-rack/native-validation-catalogs.json"
    manifest = json.loads(manifest_path.read_text())
    variants = [item for item in manifest["variants"] if not args.variant or item["name"] in args.variant]
    records = []
    with tempfile.TemporaryDirectory(prefix="astra-native-import-") as temporary:
        directory = Path(temporary)
        for item in variants:
            name = item["name"]
            source = root / item["sourcePath"]
            if not source.is_file():
                parser.error(f"Missing pinned asset: {source}")
            catalog = dict(item["catalog"], sourceURL=source.as_uri())
            catalog_path = directory / f"{name}-catalog.json"
            catalog_path.write_text(json.dumps(catalog))
            record_path = directory / f"{name}-measurement.json"
            environment = dict(os.environ, ASTRA_TEST_IMPORTED_USDZ=str(source),
                               ASTRA_TEST_IMPORTED_CATALOG=str(catalog_path),
                               ASTRA_TEST_IMPORTED_EVIDENCE=str(record_path))
            command = ["swift", "test", "--package-path", "packages/SpatialKit", "--filter",
                       "actualRackImportPreservesPartsMaterialsCacheAndTransformEdits"]
            result = subprocess.run(command, cwd=root, env=environment, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
            if result.returncode:
                print(result.stdout, file=sys.stderr)
                raise SystemExit(result.returncode)
            record = json.loads(record_path.read_text())
            record.update(variant=name, sourcePath=item["sourcePath"], approvedCatalog=item["catalog"])
            records.append(record)
            print(f"{name}: prepare {record['freshCatalog']['preparationSeconds']:.3f}s, "
                  f"install {record['freshCatalog']['installationSeconds'] * 1000:.1f}ms, "
                  f"{record['expandedTriangleCount']:,} expanded triangles", flush=True)

    tracked_sources = [
        "packages/SpatialKit/Sources/SpatialApple/Rendering/ImportedAsset.swift",
        "packages/SpatialKit/Sources/SpatialApple/Rendering/SceneRenderer.swift",
        "packages/SpatialKit/Sources/SpatialApple/SceneController.swift",
        "packages/SpatialKit/Tests/SpatialAppleTests/ImportedAssetTests.swift",
    ]
    evidence = {
        "schema": "astra-imported-rack-native-evidence/v1",
        "status": "passed",
        "reproduce": "python3 scripts/check-imported-rack-native.py",
        "catalogManifest": str(manifest_path.relative_to(root)),
        "runtimeSourceSHA256": {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
                                for path in tracked_sources},
        "scope": "Native macOS loading and scene installation; no network transfer, ARView, physical AR, or GPU FPS measurement",
        "samples": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(f"Evidence: {args.output}")


if __name__ == "__main__":
    main()
