#!/usr/bin/env python3
import json
import os
import re
from collections import Counter, deque
from http.server import BaseHTTPRequestHandler, HTTPServer


SURICATA_EVE_PATH = os.getenv("SURICATA_EVE_PATH", "/logs/suricata/eve.json")
COWRIE_LOG_PATH = os.getenv("COWRIE_LOG_PATH", "/logs/cowrie/cowrie.json")
IOC_IP_LIST_PATH = os.getenv("IOC_IP_LIST_PATH", "/ioc/opencti-indicators-ip")
IOC_DOMAIN_LIST_PATH = os.getenv("IOC_DOMAIN_LIST_PATH", "/ioc/opencti-indicators-domain")
IOC_SHA256_LIST_PATH = os.getenv("IOC_SHA256_LIST_PATH", "/ioc/opencti-indicators-sha256")
BIND_ADDRESS = os.getenv("SOC_EXPORTER_BIND", "0.0.0.0")
PORT = int(os.getenv("SOC_EXPORTER_PORT", "9150"))
LOG_SAMPLE_SIZE = int(os.getenv("LOG_SAMPLE_SIZE", "4000"))


def read_last_json_lines(path, limit):
    if not os.path.exists(path):
        return []

    lines = deque(maxlen=limit)
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line:
                lines.append(line)

    events = []
    for line in lines:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def load_indicator_values(path):
    values = set()
    if not os.path.exists(path):
        return values

    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            key = line.split(":", 1)[0].strip().lower()
            if key:
                values.add(key)
    return values


def sanitize_label(value):
    text = str(value or "unknown")
    text = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return text or "unknown"


def emit_metric_lines(metric_name, help_text, metric_type, series):
    lines = [f"# HELP {metric_name} {help_text}", f"# TYPE {metric_name} {metric_type}"]
    for labels, value in sorted(series.items()):
        if labels:
            rendered = ",".join(f'{name}="{sanitize_label(label_value)}"' for name, label_value in labels)
            lines.append(f"{metric_name}{{{rendered}}} {value}")
        else:
            lines.append(f"{metric_name} {value}")
    return lines


def normalize_severity(value):
    if value in (None, ""):
        return "unknown"
    return str(value)


def find_domain_candidates(event):
    values = []
    for parent_key, child_key in (("dns", "rrname"), ("http", "hostname"), ("tls", "sni")):
        parent = event.get(parent_key)
        if isinstance(parent, dict):
            candidate = parent.get(child_key)
            if candidate:
                values.append(str(candidate).lower())
    return values


def find_sha256_candidates(event):
    values = set()

    def walk(node):
        if isinstance(node, dict):
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)
        elif isinstance(node, str) and re.fullmatch(r"[A-Fa-f0-9]{64}", node):
            values.add(node.lower())

    walk(event)
    return values


def collect_metrics():
    suricata_events = read_last_json_lines(SURICATA_EVE_PATH, LOG_SAMPLE_SIZE)
    cowrie_events = read_last_json_lines(COWRIE_LOG_PATH, LOG_SAMPLE_SIZE)
    ioc_ips = load_indicator_values(IOC_IP_LIST_PATH)
    ioc_domains = load_indicator_values(IOC_DOMAIN_LIST_PATH)
    ioc_sha256 = load_indicator_values(IOC_SHA256_LIST_PATH)

    suricata_attackers = Counter()
    suricata_signatures = Counter()
    suricata_severities = Counter()
    cowrie_attackers = Counter()
    cowrie_login_failed = Counter()
    cowrie_events_seen = Counter()
    indicator_matches = Counter()

    for event in suricata_events:
        if event.get("event_type") != "alert":
            continue

        src_ip = str(event.get("src_ip") or "unknown")
        suricata_attackers[src_ip] += 1

        alert = event.get("alert") or {}
        signature = str(alert.get("signature") or "unknown")
        severity = normalize_severity(alert.get("severity"))
        suricata_signatures[signature] += 1
        suricata_severities[severity] += 1

        for candidate in (str(event.get("src_ip") or "").lower(), str(event.get("dest_ip") or "").lower()):
            if candidate and candidate in ioc_ips:
                indicator_matches[(("indicator", candidate), ("indicator_type", "ip"), ("source", "suricata"))] += 1

        for candidate in find_domain_candidates(event):
            if candidate in ioc_domains:
                indicator_matches[(("indicator", candidate), ("indicator_type", "domain"), ("source", "suricata"))] += 1

        for candidate in find_sha256_candidates(event):
            if candidate in ioc_sha256:
                indicator_matches[(("indicator", candidate), ("indicator_type", "sha256"), ("source", "suricata"))] += 1

    for event in cowrie_events:
        src_ip = str(event.get("src_ip") or "unknown")
        eventid = str(event.get("eventid") or "unknown")

        cowrie_attackers[src_ip] += 1
        cowrie_events_seen[eventid] += 1

        if eventid == "cowrie.login.failed":
            cowrie_login_failed[src_ip] += 1

        candidate = src_ip.lower()
        if candidate and candidate in ioc_ips:
            indicator_matches[(("indicator", candidate), ("indicator_type", "ip"), ("source", "cowrie"))] += 1

    metrics = []
    metrics.extend(
        emit_metric_lines(
            "soc_suricata_attacker_events",
            "Recent Suricata alert counts by source IP",
            "gauge",
            {(("src_ip", src_ip),): count for src_ip, count in suricata_attackers.items()},
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_suricata_signature_events",
            "Recent Suricata alert counts by signature",
            "gauge",
            {(("signature", signature),): count for signature, count in suricata_signatures.items()},
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_suricata_severity_events",
            "Recent Suricata alert counts by severity",
            "gauge",
            {(("severity", severity),): count for severity, count in suricata_severities.items()},
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_cowrie_attacker_events",
            "Recent Cowrie event counts by source IP",
            "gauge",
            {(("src_ip", src_ip),): count for src_ip, count in cowrie_attackers.items()},
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_cowrie_login_failed_events",
            "Recent Cowrie failed-login counts by source IP",
            "gauge",
            {(("src_ip", src_ip),): count for src_ip, count in cowrie_login_failed.items()},
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_cowrie_event_events",
            "Recent Cowrie event counts by event id",
            "gauge",
            {(("eventid", eventid),): count for eventid, count in cowrie_events_seen.items()},
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_opencti_indicator_matches",
            "Recent local log events matching OpenCTI-derived indicators",
            "gauge",
            indicator_matches,
        )
    )
    metrics.extend(
        emit_metric_lines(
            "soc_exporter_up",
            "Whether the lightweight SOC telemetry exporter is healthy",
            "gauge",
            {tuple(): 1},
        )
    )
    return "\n".join(metrics) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/healthz"):
            self.send_response(404)
            self.end_headers()
            return

        if self.path == "/healthz":
            payload = b"ok\n"
        else:
            payload = collect_metrics().encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format_string, *args):
        return


if __name__ == "__main__":
    server = HTTPServer((BIND_ADDRESS, PORT), MetricsHandler)
    server.serve_forever()
