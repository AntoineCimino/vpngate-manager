#!/usr/bin/env python3
"""Temporarily release Tailscale-managed DNS for explicit Tor sessions."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


class DNSError(Exception):
    pass


def tailscale(*args):
    try:
        result = subprocess.run(
            ["tailscale", *args], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DNSError("Cannot contact Tailscale; DNS settings were not confirmed.") from exc
    if result.returncode:
        raise DNSError(f"Tailscale {' '.join(args)} failed; check daemon access and privileges.")
    return result.stdout


def preferences():
    try:
        prefs = json.loads(tailscale("debug", "prefs"))
        if type(prefs.get("CorpDNS")) is not bool or type(prefs.get("WantRunning")) is not bool:
            raise ValueError("Missing boolean preferences")
        return prefs
    except (ValueError, AttributeError) as exc:
        raise DNSError("Cannot read Tailscale DNS preferences; refusing to guess prior settings.") from exc


def read_state(path):
    try:
        if path.is_symlink() or not path.is_file():
            raise ValueError("Not a regular state file")
        state = json.loads(path.read_text())
        if (not isinstance(state, dict)
                or set(state) != {"version", "accept_dns"}
                or type(state["version"]) is not int
                or state["version"] != 1
                or state["accept_dns"] is not True):
            raise ValueError("Unexpected state")
        return state
    except (OSError, ValueError) as exc:
        raise DNSError("Invalid Tor DNS recovery state; leaving it in place for inspection.") from exc


def save_state(path):
    # Persist the recovery record before changing the external daemon. Never
    # overwrite an earlier session's record or follow a symlink.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump({"version": 1, "accept_dns": True}, output)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    sync_directory(path.parent)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def remove_state(path):
    path.unlink()
    sync_directory(path.parent)


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except BlockingIOError as exc:
        raise DNSError("Another Tor DNS operation is in progress.") from exc
    finally:
        os.close(fd)


def restore(path):
    if not path.exists() and not path.is_symlink():
        return
    state = read_state(path)
    if not shutil.which("tailscale"):
        raise DNSError("Tailscale is unavailable; retain recovery state and retry restore later.")
    prefs = preferences()
    original = state["accept_dns"]
    if prefs["CorpDNS"] != original:
        tailscale("set", f"--accept-dns={str(original).lower()}")
        if preferences()["CorpDNS"] != original:
            raise DNSError("Tailscale did not restore DNS; recovery state retained for retry.")
    remove_state(path)
    print("Restored the previous Tailscale DNS preference.", file=sys.stderr)


def prepare(path):
    if not shutil.which("tailscale"):
        if path.exists() or path.is_symlink():
            raise DNSError("Recovery state exists but Tailscale is unavailable; restore it before restarting Tor.")
        return
    existing = path.exists() or path.is_symlink()
    if existing:
        read_state(path)
    prefs = preferences()
    if not prefs["WantRunning"]:
        if existing:
            raise DNSError("Unrestored Tor DNS state exists; run restore before starting a new Tor session.")
        return
    if not prefs["CorpDNS"]:
        return  # Already disabled; never turn it on during stop unless we changed it.
    if not existing:
        save_state(path)
    print(
        "Temporarily disabling Tailscale-managed DNS for Tor. "
        "MagicDNS/private DNS names may be unavailable until Tor stops.",
        file=sys.stderr,
    )
    try:
        tailscale("set", "--accept-dns=false")
        if preferences()["CorpDNS"]:
            raise DNSError("Tailscale did not release DNS; refusing to start Tor.")
    except DNSError as exc:
        try:
            restore(path)
        except DNSError:
            raise DNSError(
                "Could not release or restore Tailscale DNS; recovery state retained. "
                "Run Tor DNS restore before proceeding."
            ) from exc
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "restore"))
    parser.add_argument("state", type=Path, help="Persistent Tor DNS recovery state path")
    args = parser.parse_args()
    try:
        with locked(args.state):
            (prepare if args.action == "prepare" else restore)(args.state)
    except (DNSError, OSError) as exc:
        print(f"Tor DNS: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
