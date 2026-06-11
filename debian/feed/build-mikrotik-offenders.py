#!/usr/bin/env python3
import argparse
import csv
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

DEFAULT_FEEDS = [
    {
        "name": "firehol_level1",
        "url": "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset",
    },
    {
        "name": "dshield_topips",
        "url": "https://feeds.dshield.org/feeds/topips.txt",
    },
    {
        "name": "feodo_tracker",
        "url": "https://feodotracker.abuse.ch/downloads/ipblocklist.csv",
    },
]

TOKEN_RE = re.compile(r"(?<![0-9A-Fa-f:.])([0-9A-Fa-f:.]+(?:/\d{1,3})?)(?![0-9A-Fa-f:.])")


def parse_args():
    parser = argparse.ArgumentParser(description="Build a MikroTik RouterOS offender import file.")
    parser.add_argument("--output-dir", default="/opt/home-cinema-edge/feed/public")
    parser.add_argument("--feeds-file", default="/opt/home-cinema-edge/feed/blocklists.json")
    parser.add_argument("--list-name", default="home_cinema_offenders")
    parser.add_argument("--comment", default="home-cinema-feed")
    parser.add_argument("--timeout", default="1d")
    parser.add_argument("--max-entries", type=int, default=5000)
    parser.add_argument("--no-public-feeds", action="store_true")
    parser.add_argument("--crowdsec-command", default="cscli decisions list -o json")
    return parser.parse_args()


def load_feed_config(path):
    config_path = Path(path)
    if not config_path.exists():
        return []
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"Could not read feeds config {config_path}: {exc}", file=sys.stderr)
        return []

    if isinstance(data, dict):
        feeds = data.get("feeds", [])
    else:
        feeds = data

    valid_feeds = []
    for feed in feeds:
        if not isinstance(feed, dict):
            continue
        if feed.get("enabled", True) is False:
            continue
        name = str(feed.get("name") or "").strip()
        url = str(feed.get("url") or "").strip()
        parser = str(feed.get("parser") or "text").strip().lower()
        if not name or not url:
            continue
        if parser not in {"text", "csv"}:
            parser = "text"
        valid_feeds.append({"name": name, "url": url, "parser": parser})
    return valid_feeds


def parse_network(value):
    value = value.strip().strip('"').strip("'")
    if not value or value.startswith("#"):
        return None
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None
    if network.version != 4 or not network.is_global:
        return None
    return network


def add_candidate(entries, seen, source, value):
    network = parse_network(value)
    if network is None:
        return False
    key = str(network)
    if key in seen:
        return False
    seen.add(key)
    entries.append({"source": source, "network": network})
    return True


def extract_networks_from_text(source, text, entries, seen):
    added = 0
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        for match in TOKEN_RE.finditer(line):
            if add_candidate(entries, seen, source, match.group(1)):
                added += 1
                break
    return added


def extract_networks_from_csv(source, text, entries, seen):
    added = 0
    reader = csv.reader(line for line in text.splitlines() if line and not line.startswith("#"))
    for row in reader:
        for cell in row:
            if add_candidate(entries, seen, source, cell):
                added += 1
                break
    return added


def fetch_url(url):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "home-cinema-mikrotik-feed/1.0",
            "Accept": "text/plain,text/csv,*/*",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", errors="replace")


def load_public_feeds(entries, seen, extra_feeds=None):
    results = []
    feeds = list(DEFAULT_FEEDS)
    feeds.extend(extra_feeds or [])
    for feed in feeds:
        try:
            text = fetch_url(feed["url"])
            if feed.get("parser") == "csv" or feed["name"] == "feodo_tracker":
                count = extract_networks_from_csv(feed["name"], text, entries, seen)
            else:
                count = extract_networks_from_text(feed["name"], text, entries, seen)
            results.append({"name": feed["name"], "ok": True, "count": count})
        except Exception as exc:
            results.append({"name": feed["name"], "ok": False, "error": str(exc)})
    return results


def load_crowdsec(entries, seen, command):
    try:
        completed = subprocess.run(
            command,
            shell=True,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception as exc:
        return {"ok": False, "error": str(exc), "count": 0}

    try:
        decisions = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError as exc:
        return {"ok": False, "error": f"invalid JSON from cscli: {exc}", "count": 0}

    count = 0
    for decision in decisions:
        if not isinstance(decision, dict):
            continue
        value = decision.get("value") or decision.get("ip") or decision.get("range")
        scope = str(decision.get("scope") or "").lower()
        if value and scope in {"ip", "range", "cidr", ""}:
            if add_candidate(entries, seen, "crowdsec", str(value)):
                count += 1
    return {"ok": True, "count": count}


def routeros_quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_rsc(entries, list_name, comment, timeout):
    lines = [
        "# Generated by build-mikrotik-offenders.py",
        f"# Entries: {len(entries)}",
        f"/ip firewall address-list remove [find list={routeros_quote(list_name)} comment={routeros_quote(comment)}]",
    ]
    for item in entries:
        lines.append(
            "/ip firewall address-list add "
            f"list={routeros_quote(list_name)} "
            f"address={item['network']} "
            f"timeout={timeout} "
            f"comment={routeros_quote(comment)}"
        )
    lines.append("")
    return "\n".join(lines)


def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent), delete=False) as handle:
        handle.write(content)
        temp_name = handle.name
    os.chmod(temp_name, 0o644)
    os.replace(temp_name, path)
    os.chmod(path, 0o644)


def main():
    args = parse_args()
    entries = []
    seen = set()
    output_dir = Path(args.output_dir)

    crowdsec_result = load_crowdsec(entries, seen, args.crowdsec_command)
    feed_results = []
    if not args.no_public_feeds:
        feed_results = load_public_feeds(entries, seen, load_feed_config(args.feeds_file))
        existing_output = output_dir / "offenders.rsc"
        if not any(result.get("ok") for result in feed_results) and existing_output.exists():
            print("No public feeds could be fetched; leaving previous output untouched.", file=sys.stderr)
            print(json.dumps({"crowdsec": crowdsec_result, "feeds": feed_results}, indent=2), file=sys.stderr)
            return 2
        if not any(result.get("ok") for result in feed_results):
            print("No public feeds could be fetched; writing local CrowdSec-only feed.", file=sys.stderr)

    entries = entries[: args.max_entries]

    atomic_write(output_dir / "offenders.rsc", render_rsc(entries, args.list_name, args.comment, args.timeout))
    atomic_write(output_dir / "offenders.txt", "\n".join(str(item["network"]) for item in entries) + "\n")
    atomic_write(
        output_dir / "metadata.json",
        json.dumps(
            {
                "generated_at": int(time.time()),
                "list_name": args.list_name,
                "entries": len(entries),
                "max_entries": args.max_entries,
                "crowdsec": crowdsec_result,
                "feeds": feed_results,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
    )

    print(f"Wrote {len(entries)} entries to {output_dir / 'offenders.rsc'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
