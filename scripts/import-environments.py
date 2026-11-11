#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Save Claude environments from pasted JSON into Hermes' settings.

Hermes lists the environments saved in its settings in the session launch
sheet. This script fills that list from the JSON the Claude web app loads its
own environment list from, so the IDs don't have to be typed in one by one.

Getting the JSON:
  1. Open https://claude.ai/code in a browser, signed in.
  2. Open the developer tools, Network tab, and reload the page.
  3. Filter for "environments" and pick the request whose path ends in
     /environments?limit=1000.
  4. Copy its response body.

Usage:
  scripts/import-environments.py            # reads the clipboard, prints what it found
  scripts/import-environments.py --write    # also saves them into Hermes' settings
  scripts/import-environments.py FILE       # reads a file in place of the clipboard

Environments already saved in Hermes are kept. One with the same ID gets the
name from the JSON. A Remote Control environment, which Claude names
`host:repository:suffix`, is saved as `repository on host`. Quit Hermes before `--write` and reopen it afterwards:
Hermes reads its settings when it starts.

The script reads no cookie and makes no network request.
"""

import argparse
import json
import re
import subprocess
import sys

DOMAIN = "com.coderinserepeat.hermes"
KEY = "sessions.cloudEnvironments"
ID = re.compile(r"^(env|ccpool)_[A-Za-z0-9_-]+$")
NAME_KEYS = ("name", "display_name", "displayName", "title", "label")
# A Remote Control environment is named `host:repository:suffix`, with a four-digit hex suffix.
REMOTE = re.compile(r"^(?P<host>[^:]+):(?P<repository>[^:]+):[0-9a-f]{4}$")


def display_name(name: str) -> str:
    """`airway on junction.example.com` for a Remote Control environment; other names as they are."""
    match = REMOTE.match(name)
    return f"{match['repository']} on {match['host']}" if match else name


def environments(value) -> dict[str, str]:
    """Every object anywhere in `value` that has an environment ID, as ID -> name.

    The response's exact shape is not documented, so this does not assume one.
    """
    found: dict[str, str] = {}
    if isinstance(value, dict):
        identifier = next(
            (value[k] for k in ("id", "environment_id", "uuid") if isinstance(value.get(k), str) and ID.match(value[k])),
            None,
        )
        if identifier:
            name = next((value[k] for k in NAME_KEYS if isinstance(value.get(k), str) and value[k].strip()), identifier)
            found[identifier] = display_name(name.strip())
        for child in value.values():
            found |= {k: v for k, v in environments(child).items() if k not in found}
    elif isinstance(value, list):
        for child in value:
            found |= {k: v for k, v in environments(child).items() if k not in found}
    return found


def saved() -> list[dict[str, str]]:
    """The environments Hermes has saved now. Empty when it has none."""
    result = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True)
    if result.returncode != 0:
        return []
    import plistlib

    data = plistlib.loads(result.stdout).get(KEY)
    return json.loads(data) if data else []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", nargs="?", help="a file holding the JSON; the clipboard when left out")
    parser.add_argument("--write", action="store_true", help="save the environments into Hermes' settings")
    arguments = parser.parse_args()

    if arguments.file:
        with open(arguments.file, encoding="utf-8") as handle:
            text = handle.read()
    else:
        text = subprocess.run(["pbpaste"], capture_output=True, text=True, check=True).stdout

    # A copied response can carry text around the JSON, such as a label or a trailing newline.
    start = min((i for i in (text.find("{"), text.find("[")) if i >= 0), default=-1)
    try:
        if start < 0:
            raise json.JSONDecodeError("no { or [ in the text", text, 0)
        document, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as error:
        source = arguments.file or "the clipboard"
        print(f"No JSON in {source}: {error}", file=sys.stderr)
        print(f"It holds {len(text)} characters and starts with: {text[:60]!r}", file=sys.stderr)
        return 1
    found = environments(document)
    if not found:
        print("No environment IDs (env_… or ccpool_…) in that JSON.", file=sys.stderr)
        return 1

    merged = {entry["id"]: entry["name"] for entry in saved()} | found
    # By name, so a repository's environments on different hosts sit together in Hermes' picker.
    merged = dict(sorted(merged.items(), key=lambda item: item[1].lower()))
    for identifier, name in merged.items():
        marker = "new " if identifier in found else "kept"
        print(f"{marker}  {identifier}  {name}")

    if not arguments.write:
        print("\nNothing saved. Run again with --write to save these into Hermes.")
        return 0

    if subprocess.run(["pgrep", "-f", "Hermes.app/Contents/MacOS/Hermes"], capture_output=True).returncode == 0:
        print("\nHermes is running. Quit it first, then run this again.", file=sys.stderr)
        return 1

    # Hermes stores the list as JSON data under one key, the way its own settings code encodes it.
    payload = json.dumps([{"id": k, "name": v} for k, v in merged.items()], separators=(",", ":")).encode()
    subprocess.run(["defaults", "write", DOMAIN, KEY, "-data", payload.hex()], check=True)
    print(f"\nSaved {len(merged)} environments. Open Hermes to see them in the launch sheet.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
