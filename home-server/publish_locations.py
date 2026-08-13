#!/usr/bin/env python
"""Fetch Find My reports on the home laptop, decrypt them locally, and
publish only map coordinates for the Vercel phone UI.

Private keys never leave this computer.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

POINT_CORRECTION = 0xFFFFFFFF / 10000000.0


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def private_key_material(private_key_b64: str) -> bytes:
    key = base64.b64decode(private_key_b64)
    if len(key) > 28:
        key = key[-28:]
    return key.rjust(28, b"\x00")


def advertisement_hash(private_key_b64: str) -> str:
    priv = int.from_bytes(private_key_material(private_key_b64), "big")
    pub_x = (
        ec.derive_private_key(priv, ec.SECP224R1(), default_backend())
        .public_key()
        .public_numbers()
        .x
    )
    adv_bytes = pub_x.to_bytes(28, "big")
    return base64.b64encode(sha256(adv_bytes)).decode("ascii")


def correct_coordinate(coordinate: float, threshold: int) -> float:
    if coordinate > threshold:
        coordinate -= POINT_CORRECTION
    if coordinate < -threshold:
        coordinate += POINT_CORRECTION
    return coordinate


def decrypt_report(payload_b64: str, private_key_b64: str) -> dict | None:
    payload = bytearray(base64.b64decode(payload_b64))
    if len(payload) > 88:
        del payload[4]
    data = bytes(payload)
    if len(data) < 82:
        return None

    seen = int.from_bytes(data[0:4], "big")
    timestamp = datetime.fromtimestamp(seen + 978307200, tz=timezone.utc)
    eph_bytes = data[5:62]
    enc_data = data[62:72]
    tag = data[72:]

    priv = int.from_bytes(private_key_material(private_key_b64), "big")
    private_key = ec.derive_private_key(priv, ec.SECP224R1(), default_backend())
    eph_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP224R1(), eph_bytes)
    shared = private_key.exchange(ec.ECDH(), eph_key)

    derived = hashlib.sha256(shared + (1).to_bytes(4, "big") + eph_bytes).digest()
    plaintext = AESGCM(derived[:16]).decrypt(derived[16:], enc_data + tag, None)

    latitude = int.from_bytes(plaintext[0:4], "big") / 10000000.0
    longitude = int.from_bytes(plaintext[4:8], "big") / 10000000.0
    accuracy = plaintext[8]
    latitude = correct_coordinate(latitude, 90)
    longitude = correct_coordinate(longitude, 180)
    if abs(latitude) > 90 or abs(longitude) > 180:
        return None
    return {
        "latitude": latitude,
        "longitude": longitude,
        "accuracy": accuracy,
        "timestamp": timestamp.isoformat(),
    }


def load_devices(path: Path) -> list[dict]:
    devices = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(devices, list):
        raise ValueError("devices.json must be a JSON array")
    return devices


def collect_keys(device: dict) -> list[str]:
    keys = [device["privateKey"]]
    keys.extend(device.get("additionalKeys") or [])
    return [key for key in keys if key]


def fetch_reports(endpoint: str, hashed_ids: list[str], days: int) -> list[dict]:
    response = requests.post(
        endpoint,
        json={"ids": hashed_ids, "days": days},
        timeout=120,
    )
    response.raise_for_status()
    return response.json().get("results") or []


def latest_location(device: dict, reports: list[dict]) -> dict | None:
    key_by_hash = {
        advertisement_hash(private_key): private_key
        for private_key in collect_keys(device)
    }
    best = None
    for report in reports:
        private_key = key_by_hash.get(report.get("id"))
        if not private_key or "payload" not in report:
            continue
        try:
            decoded = decrypt_report(report["payload"], private_key)
        except Exception:
            continue
        if decoded is None:
            continue
        if best is None or decoded["timestamp"] > best["timestamp"]:
            best = decoded
    return best


def write_locations(path: Path, trackers: list[dict]) -> None:
    payload = {
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "trackers": trackers,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def git_publish(repo: Path, locations_file: Path) -> None:
    relative = locations_file.relative_to(repo).as_posix()
    subprocess.run(["git", "add", "--", relative], cwd=repo, check=True)
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", relative],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    if not status.stdout.strip():
        print("No location change to publish.")
        return
    subprocess.run(
        [
            "git",
            "commit",
            "-m",
            "Update published tracker locations from the home laptop.",
        ],
        cwd=repo,
        check=True,
    )
    subprocess.run(["git", "push", "origin", "HEAD"], cwd=repo, check=True)
    print("Published locations to GitHub/Vercel.")


def publish_once(args: argparse.Namespace) -> int:
    devices = load_devices(Path(args.devices))
    hashed_ids: list[str] = []
    for device in devices:
        hashed_ids.extend(advertisement_hash(key) for key in collect_keys(device))
    hashed_ids = list(dict.fromkeys(hashed_ids))
    print(f"Asking local Haystack endpoint for {len(hashed_ids)} key(s).")
    reports = fetch_reports(args.endpoint, hashed_ids, args.days)
    print(f"Received {len(reports)} encrypted report(s).")

    trackers = []
    for device in devices:
        location = latest_location(device, reports)
        tracker = {
            "id": str(device.get("id", device.get("name", "tracker"))),
            "name": device.get("name", "Tracker"),
            "icon": device.get("icon") or "mappin",
        }
        if location:
            tracker.update(location)
            print(f"{tracker['name']}: {location['latitude']:.5f}, {location['longitude']:.5f}")
        else:
            print(f"{tracker['name']}: no location report yet")
        trackers.append(tracker)

    locations_path = Path(args.output)
    write_locations(locations_path, trackers)
    if args.repo:
        git_publish(Path(args.repo), locations_path)
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Decrypt Find My reports on the home laptop and publish coordinates."
    )
    parser.add_argument(
        "--devices",
        default=r"C:\Users\siddh\haystack-secrets\devices.json",
        help="Path to _devices.json. Kept only on this laptop.",
    )
    parser.add_argument("--endpoint", default="http://localhost:6176")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument(
        "--output",
        default=r"C:\Users\siddh\Documents\sai_airtag\public\locations.json",
    )
    parser.add_argument(
        "--repo",
        default=r"C:\Users\siddh\Documents\sai_airtag",
        help="Git repo Vercel deploys.",
    )
    parser.add_argument(
        "--skip-git",
        action="store_true",
        help="Write locations.json without pushing to GitHub.",
    )
    parser.add_argument("--interval", type=int, default=0, help="Repeat every N seconds.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.skip_git:
        args.repo = None
    while True:
        try:
            publish_once(args)
        except Exception as exc:
            print(f"Publish failed: {exc}", file=sys.stderr)
            if args.interval <= 0:
                return 1
        if args.interval <= 0:
            return 0
        print(f"Sleeping {args.interval} seconds.")
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
