#!/usr/bin/env python3
import json
import os
import random
import socket
import ssl
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parent
ASSET_ROOT = APP_ROOT / "service_index_assets"
CATALOG_PATH = ASSET_ROOT / "service_catalog.json"
DOCS_ROOT = Path(os.getenv("SERVICE_INDEX_DOCS_ROOT", "/docs")).resolve()
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
BIND = os.getenv("SERVICE_INDEX_BIND", "0.0.0.0")
PORT = int(os.getenv("SERVICE_INDEX_PORT", "9088"))
REQUEST_TIMEOUT = float(os.getenv("SERVICE_INDEX_TIMEOUT_SECONDS", "5"))

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/assets/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/assets/styles.css": ("styles.css", "text/css; charset=utf-8"),
}


def load_catalog():
    with CATALOG_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def http_check(check):
    url = check["target"]
    allowed_statuses = set(check.get("allowed_statuses") or [200])
    request = urllib.request.Request(url, method=check.get("method", "GET"))
    context = None
    if check.get("skip_tls_verify"):
        context = ssl._create_unverified_context()

    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT, context=context) as response:
            status_code = response.getcode()
            return (
                status_code in allowed_statuses,
                f"HTTP {status_code}",
            )
    except urllib.error.HTTPError as error:
        if error.code in allowed_statuses:
            return True, f"HTTP {error.code}"
        return False, f"HTTP {error.code}"
    except Exception as error:  # noqa: BLE001
        return False, str(error)


def tcp_check(check):
    host = check["host"]
    port = int(check["port"])
    try:
        with socket.create_connection((host, port), timeout=REQUEST_TIMEOUT):
            return True, f"TCP {host}:{port}"
    except Exception as error:  # noqa: BLE001
        return False, str(error)


def encode_dns_name(name):
    parts = []
    for label in name.strip(".").split("."):
        encoded = label.encode("ascii")
        parts.append(bytes([len(encoded)]))
        parts.append(encoded)
    parts.append(b"\x00")
    return b"".join(parts)


def dns_check(check):
    server = check["server"]
    port = int(check.get("port", 53))
    query_name = check.get("query_name", "example.com")
    query_type = 1
    transaction_id = random.randint(0, 65535)
    packet = struct.pack("!HHHHHH", transaction_id, 0x0100, 1, 0, 0, 0)
    packet += encode_dns_name(query_name)
    packet += struct.pack("!HH", query_type, 1)

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(REQUEST_TIMEOUT)
            sock.sendto(packet, (server, port))
            response, _ = sock.recvfrom(512)
    except Exception as error:  # noqa: BLE001
        return False, str(error)

    if len(response) < 12:
        return False, "DNS response too short"

    response_id, flags, _, answer_count, _, _ = struct.unpack("!HHHHHH", response[:12])
    if response_id != transaction_id:
        return False, "DNS transaction ID mismatch"

    rcode = flags & 0x000F
    if rcode != 0:
        return False, f"DNS rcode {rcode}"

    if answer_count < 1:
        return False, "DNS response contained no answers"

    return True, f"DNS {query_name} answered"


def run_check(service):
    started = time.perf_counter()
    check = service.get("check") or {}
    check_type = check.get("type")

    if check_type == "http":
        healthy, detail = http_check(check)
    elif check_type == "tcp":
        healthy, detail = tcp_check(check)
    elif check_type == "dns":
        healthy, detail = dns_check(check)
    else:
        healthy, detail = False, f"Unsupported check type: {check_type}"

    latency_ms = round((time.perf_counter() - started) * 1000, 1)
    return {
        "healthy": healthy,
        "status": "healthy" if healthy else "critical",
        "detail": detail,
        "latency_ms": latency_ms,
    }


def fetch_active_alerts():
    query = urllib.parse.quote('ALERTS{alertstate="firing"}', safe="")
    url = f"{PROMETHEUS_URL}/api/v1/query?query={query}"
    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT) as response:
            payload = json.load(response)
    except Exception:  # noqa: BLE001
        return []

    alerts = []
    for item in payload.get("data", {}).get("result", []):
        metric = item.get("metric", {})
        alerts.append(
            {
                "alertname": metric.get("alertname", "unknown"),
                "severity": metric.get("severity", "unknown"),
                "instance": metric.get("instance", ""),
                "service_name": metric.get("service_name", ""),
                "job": metric.get("job", ""),
            }
        )

    alerts.sort(key=lambda item: (item["severity"], item["alertname"], item["instance"]))
    return alerts


def list_pdfs():
    docs = []
    if not DOCS_ROOT.exists():
        return docs

    for path in sorted(DOCS_ROOT.glob("*.pdf")):
        docs.append(
            {
                "name": path.stem.replace("-", " ").title(),
                "filename": path.name,
                "url": f"/docs/{urllib.parse.quote(path.name)}",
            }
        )
    return docs


def build_payload():
    catalog = load_catalog()
    services = []
    for service in catalog.get("services", []):
        result = run_check(service)
        services.append(
            {
                "id": service["id"],
                "name": service["name"],
                "url": service["url"],
                "username": service.get("username", "none"),
                "password_source": service.get("password_source", "none"),
                "notes": service.get("notes", ""),
                "group": service.get("group", "general"),
                "status": result["status"],
                "detail": result["detail"],
                "healthy": result["healthy"],
                "latency_ms": result["latency_ms"],
            }
        )

    healthy_count = sum(1 for item in services if item["healthy"])
    payload = {
        "title": catalog.get("title", "Monitoring Service Index"),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "summary": {
            "total": len(services),
            "healthy": healthy_count,
            "critical": len(services) - healthy_count,
        },
        "services": services,
        "docs": list_pdfs(),
        "alerts": fetch_active_alerts(),
    }
    return payload


class ServiceIndexHandler(BaseHTTPRequestHandler):
    def log_message(self, format_string, *args):  # noqa: A003
        return

    def _send_json(self, payload, status_code=200, send_body=True):
        encoded = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        if send_body:
            self.wfile.write(encoded)

    def _send_file(self, path, content_type, send_body=True):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def _handle_request(self, send_body):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "2")
            self.end_headers()
            if send_body:
                self.wfile.write(b"ok")
            return

        if self.path == "/api/status":
            self._send_json(build_payload(), send_body=send_body)
            return

        if self.path.startswith("/docs/"):
            filename = urllib.parse.unquote(self.path.split("/docs/", 1)[1])
            path = DOCS_ROOT / filename
            if path.is_file() and path.suffix.lower() == ".pdf":
                self._send_file(path, "application/pdf", send_body=send_body)
                return
            self.send_error(404)
            return

        static_entry = STATIC_FILES.get(self.path)
        if static_entry:
            asset_name, content_type = static_entry
            asset_path = ASSET_ROOT / asset_name
            if asset_path.is_file():
                self._send_file(asset_path, content_type, send_body=send_body)
                return

        self.send_error(404)

    def do_GET(self):  # noqa: N802
        self._handle_request(send_body=True)

    def do_HEAD(self):  # noqa: N802
        self._handle_request(send_body=False)


def main():
    server = ThreadingHTTPServer((BIND, PORT), ServiceIndexHandler)
    print(f"Monitoring service index listening on {BIND}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
