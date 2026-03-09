#!/usr/bin/env python3
import argparse
import csv
import ipaddress
import re
from pathlib import Path


SHA256_RE = re.compile(r"^[A-Fa-f0-9]{64}$")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?!-)[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$")


def classify_indicator(value):
    text = value.strip().lower()
    if not text:
        return None, None

    try:
        ipaddress.ip_address(text)
        return "ip", text
    except ValueError:
        pass

    if SHA256_RE.fullmatch(text):
        return "sha256", text

    if DOMAIN_RE.fullmatch(text):
        return "domain", text

    if text.startswith("[ipv4-addr:value = '") and text.endswith("']"):
        return "ip", text.split("'")[1].lower()

    if text.startswith("[domain-name:value = '") and text.endswith("']"):
        return "domain", text.split("'")[1].lower()

    return None, None


def extract_candidate(row):
    for key in (
        "value",
        "observable_value",
        "pattern",
        "Indicator value",
        "Main observable",
        "name",
    ):
        candidate = row.get(key)
        if candidate:
            return candidate
    return ""


def write_cdb_list(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for value in sorted(values):
            handle.write(f"{value}:opencti\n")


def main():
    parser = argparse.ArgumentParser(description="Convert an OpenCTI CSV export into Wazuh CDB list files.")
    parser.add_argument("csv_path", help="Path to the CSV export produced from OpenCTI.")
    parser.add_argument(
        "--output-dir",
        default=str(Path(__file__).resolve().parents[3] / "wazuh-docker-stack" / "single-node" / "config" / "wazuh_cluster" / "lists"),
        help="Destination directory for Wazuh list files.",
    )
    args = parser.parse_args()

    outputs = {"ip": set(), "domain": set(), "sha256": set()}

    with open(args.csv_path, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            indicator_type, value = classify_indicator(extract_candidate(row))
            if indicator_type:
                outputs[indicator_type].add(value)

    output_dir = Path(args.output_dir)
    write_cdb_list(output_dir / "opencti-indicators-ip", outputs["ip"])
    write_cdb_list(output_dir / "opencti-indicators-domain", outputs["domain"])
    write_cdb_list(output_dir / "opencti-indicators-sha256", outputs["sha256"])

    print(f"Wrote {len(outputs['ip'])} IP indicators")
    print(f"Wrote {len(outputs['domain'])} domain indicators")
    print(f"Wrote {len(outputs['sha256'])} SHA256 indicators")


if __name__ == "__main__":
    main()
