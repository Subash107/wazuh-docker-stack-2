#!/usr/bin/env python3
import html
import json
import os
import re
import socket
import time
from pathlib import Path


REPO_ROOT = Path(os.getenv("MONITORING_REPO_ROOT") or Path(__file__).resolve().parents[2])
PRIVATE_ROOT = REPO_ROOT / "local" / "operator-private"
OUTPUT_HTML = PRIVATE_ROOT / "credential-export.html"
OUTPUT_JSON = PRIVATE_ROOT / "credential-export.json"
LAUNCHER_HTML = PRIVATE_ROOT / "launcher.html"
LAUNCHER_JSON = PRIVATE_ROOT / "launcher.json"
OVERRIDE_JSON = PRIVATE_ROOT / "credentials.override.json"
CATALOG_PATH = REPO_ROOT / "scripts" / "python" / "service_index_assets" / "service_catalog.json"
ROOT_ENV_PATH = REPO_ROOT / ".env"
WAZUH_ENV_PATH = REPO_ROOT / "wazuh-docker-stack" / ".env"
WAZUH_SECRET_ROOT = REPO_ROOT / "wazuh-docker-stack" / "secrets"
HOST_SECRET_ROOT = REPO_ROOT / "secrets"
ALERTMANAGER_PATH = REPO_ROOT / "alertmanager.yml"
SMTP_KEY_PATH = REPO_ROOT / "secrets" / "brevo_smtp_key.txt"
PDF_ROOT = REPO_ROOT / "docs" / "pdf-handbook"
WAZUH_INDEXER_PASSWORD_PATH = WAZUH_SECRET_ROOT / "indexer_password.txt"
WAZUH_API_PASSWORD_PATH = WAZUH_SECRET_ROOT / "api_password.txt"
WAZUH_DASHBOARD_PASSWORD_PATH = WAZUH_SECRET_ROOT / "dashboard_password.txt"
VM_SSH_PASSWORD_PATH = HOST_SECRET_ROOT / "vm_ssh_password.txt"
VM_SUDO_PASSWORD_PATH = HOST_SECRET_ROOT / "vm_sudo_password.txt"
PIHOLE_WEB_PASSWORD_PATH = HOST_SECRET_ROOT / "pihole_web_password.txt"


def parse_env_file(path):
    values = {}
    if not path.exists():
        return values

    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values


def load_json(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8-sig"))


def extract_yaml_scalar(text, key):
    pattern = rf"(?m)^\s*{re.escape(key)}:\s*\"?([^\n\"]+)\"?\s*$"
    match = re.search(pattern, text)
    return match.group(1).strip() if match else ""


def read_text(path):
    return path.read_text(encoding="utf-8-sig").strip() if path.exists() else ""


def prefer(*candidates):
    for value in candidates:
        if value not in (None, ""):
            return value
    return ""


def build_source_label(value, source_name):
    return source_name if value else "not available"


def resolve_secret(file_path, *, override_value="", env_name="", legacy_value="", legacy_label=""):
    file_value = read_text(file_path)
    if file_value:
        return file_value, str(file_path.relative_to(REPO_ROOT)).replace("\\", "/")

    if override_value not in (None, ""):
        return str(override_value), "local/operator-private/credentials.override.json"

    if env_name:
        env_value = os.getenv(env_name, "").strip()
        if env_value:
            return env_value, env_name

    if legacy_value not in (None, ""):
        return str(legacy_value), legacy_label or "legacy local config"

    return "", "not available"


def build_service_entry(service_id, service_map, username, password, password_source, notes=None):
    service = service_map.get(service_id, {})
    return {
        "id": service_id,
        "name": service.get("name", service_id),
        "url": service.get("url", ""),
        "username": username or "none",
        "password": password or "not available",
        "password_source": password_source,
        "notes": notes or service.get("notes", ""),
    }


def build_extra_entry(name, endpoint, username, password, password_source, notes):
    return {
        "name": name,
        "url": endpoint,
        "username": username or "none",
        "password": password or "not available",
        "password_source": password_source,
        "notes": notes,
    }


def render_card(entry, include_url=True):
    url_line = ""
    if include_url and entry.get("url"):
        url_line = (
            "<div class='field'><span class='label'>URL or Endpoint</span>"
            f"<code>{html.escape(entry['url'])}</code></div>"
        )

    return (
        "<article class='card'>"
        f"<h2>{html.escape(entry['name'])}</h2>"
        f"{url_line}"
        "<div class='field'><span class='label'>Username</span>"
        f"<code>{html.escape(entry['username'])}</code></div>"
        "<div class='field'><span class='label'>Password</span>"
        f"<code>{html.escape(entry['password'])}</code></div>"
        "<div class='field'><span class='label'>Password Source</span>"
        f"<span>{html.escape(entry['password_source'])}</span></div>"
        "<div class='field'><span class='label'>Notes</span>"
        f"<span>{html.escape(entry['notes'])}</span></div>"
        "</article>"
    )


def build_html(payload):
    service_cards = "\n".join(render_card(item) for item in payload["services"])
    extra_cards = "\n".join(render_card(item, include_url=bool(item.get("url"))) for item in payload["extras"])
    return f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Private Credential Export</title>
    <style>
      :root {{
        --bg: #f4efe4;
        --panel: rgba(255, 251, 243, 0.96);
        --ink: #1f2933;
        --muted: #5b6670;
        --line: rgba(31, 41, 51, 0.12);
        --warn: #8a2d1f;
        --shadow: 0 18px 36px rgba(26, 33, 41, 0.08);
      }}
      * {{ box-sizing: border-box; }}
      body {{
        margin: 0;
        font-family: "Trebuchet MS", "Segoe UI", sans-serif;
        color: var(--ink);
        background:
          radial-gradient(circle at top left, rgba(210, 166, 94, 0.2), transparent 24rem),
          linear-gradient(180deg, #f8f4ec 0%, var(--bg) 100%);
      }}
      main {{
        width: min(1200px, calc(100vw - 2rem));
        margin: 0 auto;
        padding: 2rem 0 3rem;
      }}
      .hero, .section {{
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 1.25rem;
        box-shadow: var(--shadow);
      }}
      .hero {{
        padding: 1.5rem 1.75rem;
      }}
      .eyebrow {{
        margin: 0 0 0.5rem;
        text-transform: uppercase;
        letter-spacing: 0.12em;
        font-size: 0.78rem;
        color: var(--muted);
      }}
      h1, h2, p {{ margin: 0; }}
      h1 {{
        font-size: clamp(2rem, 3vw, 3rem);
        line-height: 1;
      }}
      .warning {{
        margin-top: 1rem;
        padding: 0.95rem 1rem;
        border-radius: 1rem;
        background: rgba(138, 45, 31, 0.08);
        color: var(--warn);
        font-weight: 700;
      }}
      .meta {{
        margin-top: 0.9rem;
        color: var(--muted);
        line-height: 1.6;
      }}
      .section {{
        margin-top: 1.2rem;
        padding: 1.3rem;
      }}
      .grid {{
        display: grid;
        gap: 1rem;
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
        margin-top: 1rem;
      }}
      .card {{
        padding: 1rem;
        border-radius: 1rem;
        border: 1px solid var(--line);
        background: rgba(255, 255, 255, 0.72);
      }}
      .card h2 {{
        font-size: 1.05rem;
      }}
      .field {{
        margin-top: 0.7rem;
      }}
      .label {{
        display: block;
        margin-bottom: 0.28rem;
        font-size: 0.76rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--muted);
      }}
      code {{
        display: block;
        padding: 0.65rem 0.75rem;
        border-radius: 0.8rem;
        background: #f4efe7;
        border: 1px solid rgba(31, 41, 51, 0.08);
        white-space: pre-wrap;
        word-break: break-word;
        font-family: Consolas, "Courier New", monospace;
      }}
      @media (max-width: 720px) {{
        main {{
          width: min(100vw - 1rem, 1200px);
          padding-top: 1rem;
        }}
        .hero, .section {{
          padding: 1rem;
        }}
      }}
    </style>
  </head>
  <body>
    <main>
      <section class="hero">
        <p class="eyebrow">Local Only</p>
        <h1>Private Credential Export</h1>
        <p class="meta">Generated at {html.escape(payload["generated_at"])} on {html.escape(payload["machine_name"])}</p>
        <p class="warning">This file contains live credentials. Keep it on this machine only. The folder is gitignored and not exposed by the LAN service index.</p>
      </section>

      <section class="section">
        <h2>Service Credentials</h2>
        <div class="grid">
          {service_cards}
        </div>
      </section>

      <section class="section">
        <h2>Additional Secrets</h2>
        <div class="grid">
          {extra_cards}
        </div>
      </section>
    </main>
  </body>
</html>
"""


def build_relative_path(path):
    return os.path.relpath(path, PRIVATE_ROOT).replace("\\", "/")


def build_launcher_html(payload, launcher_payload):
    quick_link_cards = "\n".join(
        (
            "<a class='action-card' href='{href}' target='{target}' rel='{rel}'>"
            "<span class='action-eyebrow'>{eyebrow}</span>"
            "<strong>{name}</strong>"
            "<span>{note}</span>"
            "</a>"
        ).format(
            href=html.escape(item["href"]),
            target=html.escape(item["target"]),
            rel=html.escape(item["rel"]),
            eyebrow=html.escape(item["eyebrow"]),
            name=html.escape(item["name"]),
            note=html.escape(item["note"]),
        )
        for item in launcher_payload["quick_links"]
    )
    doc_cards = "\n".join(
        (
            "<a class='doc-card' href='{href}' target='_blank' rel='noreferrer'>"
            "<span class='doc-name'>{name}</span>"
            "<span class='doc-action'>Open PDF</span>"
            "</a>"
        ).format(
            href=html.escape(item["href"]),
            name=html.escape(item["name"]),
        )
        for item in launcher_payload["docs"]
    )
    service_cards = "\n".join(
        (
            "<a class='service-card' href='{href}' target='{target}' rel='{rel}'>"
            "<span class='service-group'>{group}</span>"
            "<strong>{name}</strong>"
            "<span class='service-url'>{url}</span>"
            "<span class='service-note'>{note}</span>"
            "</a>"
        ).format(
            href=html.escape(item["href"]),
            target=html.escape(item["target"]),
            rel=html.escape(item["rel"]),
            group=html.escape(item["group"]),
            name=html.escape(item["name"]),
            url=html.escape(item["url"]),
            note=html.escape(item["note"]),
        )
        for item in launcher_payload["service_links"]
    )

    return f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Private Operator Launcher</title>
    <style>
      :root {{
        --bg: #efe8d7;
        --panel: rgba(255, 251, 242, 0.94);
        --panel-strong: rgba(255, 255, 255, 0.82);
        --ink: #1d2730;
        --muted: #5b6771;
        --line: rgba(29, 39, 48, 0.12);
        --accent: #204e72;
        --accent-soft: rgba(32, 78, 114, 0.08);
        --shadow: 0 18px 40px rgba(30, 34, 39, 0.09);
      }}
      * {{ box-sizing: border-box; }}
      body {{
        margin: 0;
        min-height: 100vh;
        font-family: "Trebuchet MS", "Segoe UI", sans-serif;
        color: var(--ink);
        background:
          radial-gradient(circle at top left, rgba(201, 156, 71, 0.18), transparent 24rem),
          radial-gradient(circle at top right, rgba(58, 103, 124, 0.12), transparent 20rem),
          linear-gradient(180deg, #f7f2e8 0%, var(--bg) 100%);
      }}
      main {{
        width: min(1200px, calc(100vw - 2rem));
        margin: 0 auto;
        padding: 2rem 0 3rem;
      }}
      .hero, .section {{
        border: 1px solid var(--line);
        border-radius: 1.35rem;
        background: var(--panel);
        box-shadow: var(--shadow);
      }}
      .hero {{
        padding: 1.75rem;
      }}
      .eyebrow {{
        margin: 0 0 0.45rem;
        font-size: 0.78rem;
        text-transform: uppercase;
        letter-spacing: 0.13em;
        color: var(--muted);
      }}
      h1, h2, p {{
        margin: 0;
      }}
      h1 {{
        font-size: clamp(2rem, 3vw, 3rem);
        line-height: 1;
      }}
      .hero-copy {{
        margin-top: 0.85rem;
        max-width: 56rem;
        color: var(--muted);
        line-height: 1.6;
      }}
      .meta {{
        margin-top: 1rem;
        color: var(--muted);
        line-height: 1.5;
      }}
      .warning {{
        margin-top: 1rem;
        padding: 0.95rem 1rem;
        border-radius: 1rem;
        background: rgba(121, 41, 29, 0.08);
        color: #7a291d;
        font-weight: 700;
      }}
      .section {{
        margin-top: 1.2rem;
        padding: 1.35rem;
      }}
      .section-head {{
        display: flex;
        flex-wrap: wrap;
        gap: 0.65rem;
        justify-content: space-between;
        align-items: end;
        margin-bottom: 1rem;
      }}
      .section-head p {{
        color: var(--muted);
      }}
      .grid {{
        display: grid;
        gap: 1rem;
      }}
      .quick-grid {{
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      }}
      .docs-grid {{
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      }}
      .services-grid {{
        grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      }}
      .action-card,
      .doc-card,
      .service-card {{
        display: flex;
        flex-direction: column;
        gap: 0.65rem;
        padding: 1rem;
        border: 1px solid var(--line);
        border-radius: 1rem;
        background: var(--panel-strong);
        box-shadow: var(--shadow);
        color: inherit;
        text-decoration: none;
      }}
      .action-card {{
        background: linear-gradient(145deg, rgba(255, 252, 246, 0.95), rgba(239, 246, 251, 0.9));
      }}
      .action-eyebrow,
      .service-group {{
        display: inline-flex;
        width: fit-content;
        padding: 0.24rem 0.55rem;
        border-radius: 999px;
        background: var(--accent-soft);
        color: var(--accent);
        font-size: 0.76rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
      }}
      .doc-name,
      .service-card strong,
      .action-card strong {{
        font-size: 1.02rem;
      }}
      .doc-action,
      .service-url,
      .service-note,
      .action-card span:last-child {{
        color: var(--muted);
        line-height: 1.5;
      }}
      @media (max-width: 720px) {{
        main {{
          width: min(100vw - 1rem, 1200px);
          padding-top: 1rem;
        }}
        .hero, .section {{
          padding: 1rem;
        }}
      }}
    </style>
  </head>
  <body>
    <main>
      <section class="hero">
        <p class="eyebrow">Local Only</p>
        <h1>Private Operator Launcher</h1>
        <p class="hero-copy">One-click local entry point for the LAN service index, the private credential export, and the PDF handbook set.</p>
        <p class="meta">Generated at {html.escape(payload["generated_at"])} on {html.escape(payload["machine_name"])}</p>
        <p class="warning">This page stays local to this machine. It links to live dashboards and the private credential export, but it is not served over the LAN.</p>
      </section>

      <section class="section">
        <div class="section-head">
          <div>
            <h2>Quick Actions</h2>
            <p>Open the main operator entry points directly.</p>
          </div>
        </div>
        <div class="grid quick-grid">
          {quick_link_cards}
        </div>
      </section>

      <section class="section">
        <div class="section-head">
          <div>
            <h2>Handbook PDFs</h2>
            <p>Offline documentation in one folder.</p>
          </div>
        </div>
        <div class="grid docs-grid">
          {doc_cards}
        </div>
      </section>

      <section class="section">
        <div class="section-head">
          <div>
            <h2>Direct Service Links</h2>
            <p>LAN dashboards and sensor tools from the same page.</p>
          </div>
        </div>
        <div class="grid services-grid">
          {service_cards}
        </div>
      </section>
    </main>
  </body>
</html>
"""


def build_launcher_payload(payload, catalog):
    docs = []
    for path in sorted(PDF_ROOT.glob("*.pdf")):
        docs.append(
            {
                "name": path.stem.replace("-", " ").title(),
                "filename": path.name,
                "href": build_relative_path(path),
            }
        )

    quick_links = [
        {
            "eyebrow": "LAN",
            "name": "Public Service Index",
            "href": "http://192.168.1.3:9088",
            "target": "_blank",
            "rel": "noreferrer",
            "note": "Health, links, and PDF access for the monitoring stack.",
        },
        {
            "eyebrow": "Local",
            "name": "Private Credential Export",
            "href": OUTPUT_HTML.name,
            "target": "_blank",
            "rel": "noreferrer",
            "note": "Live usernames and passwords stored only on this machine.",
        },
        {
            "eyebrow": "PDF",
            "name": "Installation Guide PDF",
            "href": build_relative_path(PDF_ROOT / "installation-guide.pdf"),
            "target": "_blank",
            "rel": "noreferrer",
            "note": "Primary operator install reference from the offline handbook set.",
        },
        {
            "eyebrow": "PDF",
            "name": "Threat Guide PDF",
            "href": build_relative_path(PDF_ROOT / "monitoring-and-threat-identification-guide.pdf"),
            "target": "_blank",
            "rel": "noreferrer",
            "note": "Investigation and threat-identification workflow guide.",
        },
        {
            "eyebrow": "Local",
            "name": "Override Input",
            "href": OVERRIDE_JSON.name,
            "target": "_blank",
            "rel": "noreferrer",
            "note": "Edit missing local-only secret values before regenerating.",
        },
    ]

    service_links = []
    for item in catalog.get("services", []):
        url = item.get("url", "")
        if not url or url.startswith("ssh ") or "://" not in url:
            continue
        service_links.append(
            {
                "name": item.get("name", item.get("id", "service")),
                "group": item.get("group", "general"),
                "href": url,
                "target": "_blank",
                "rel": "noreferrer",
                "url": url,
                "note": item.get("notes", ""),
            }
        )

    return {
        "generated_at": payload["generated_at"],
        "machine_name": payload["machine_name"],
        "quick_links": quick_links,
        "docs": docs,
        "service_links": service_links,
    }


def main():
    root_env = parse_env_file(ROOT_ENV_PATH)
    wazuh_env = parse_env_file(WAZUH_ENV_PATH)
    overrides = load_json(OVERRIDE_JSON)
    catalog = load_json(CATALOG_PATH)
    alertmanager_text = read_text(ALERTMANAGER_PATH)
    smtp_password = read_text(SMTP_KEY_PATH)
    service_map = {item["id"]: item for item in catalog.get("services", [])}

    pihole_password, pihole_password_source = resolve_secret(
        PIHOLE_WEB_PASSWORD_PATH,
        override_value=overrides.get("pihole_password"),
        env_name="PIHOLE_WEBPASSWORD",
    )
    sensor_ssh_password, sensor_ssh_password_source = resolve_secret(
        VM_SSH_PASSWORD_PATH,
        override_value=overrides.get("sensor_ssh_password"),
        env_name="VM_SSH_PASSWORD",
    )
    sensor_sudo_password, sensor_sudo_password_source = resolve_secret(
        VM_SUDO_PASSWORD_PATH,
        override_value=overrides.get("sensor_sudo_password"),
        env_name="VM_SUDO_PASSWORD",
    )
    wazuh_dashboard_password, wazuh_dashboard_password_source = resolve_secret(
        WAZUH_INDEXER_PASSWORD_PATH,
        override_value=overrides.get("wazuh_dashboard_password"),
        legacy_value=wazuh_env.get("INDEXER_PASSWORD"),
        legacy_label="wazuh-docker-stack/.env INDEXER_PASSWORD",
    )
    wazuh_api_password, wazuh_api_password_source = resolve_secret(
        WAZUH_API_PASSWORD_PATH,
        override_value=overrides.get("wazuh_api_password"),
        legacy_value=wazuh_env.get("API_PASSWORD"),
        legacy_label="wazuh-docker-stack/.env API_PASSWORD",
    )
    wazuh_indexer_password, wazuh_indexer_password_source = resolve_secret(
        WAZUH_INDEXER_PASSWORD_PATH,
        override_value=overrides.get("wazuh_indexer_password"),
        legacy_value=wazuh_env.get("INDEXER_PASSWORD"),
        legacy_label="wazuh-docker-stack/.env INDEXER_PASSWORD",
    )
    wazuh_dashboard_service_password, wazuh_dashboard_service_password_source = resolve_secret(
        WAZUH_DASHBOARD_PASSWORD_PATH,
        override_value=overrides.get("wazuh_dashboard_service_password"),
        legacy_value=wazuh_env.get("DASHBOARD_PASSWORD"),
        legacy_label="wazuh-docker-stack/.env DASHBOARD_PASSWORD",
    )
    smtp_username = extract_yaml_scalar(alertmanager_text, "smtp_auth_username")
    smtp_from = extract_yaml_scalar(alertmanager_text, "smtp_from")
    smtp_smarthost = extract_yaml_scalar(alertmanager_text, "smtp_smarthost")
    stack_email_to = extract_yaml_scalar(alertmanager_text, "to")

    machine_name = prefer(
        os.getenv("OPERATOR_MACHINE_NAME"),
        os.getenv("COMPUTERNAME"),
        os.getenv("HOSTNAME"),
        socket.gethostname(),
    )
    payload = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "machine_name": machine_name,
        "services": [
            build_service_entry(
                "service-index",
                service_map,
                "none",
                "",
                "none",
                "LAN-visible page for links, health, and PDFs only.",
            ),
            build_service_entry(
                "wazuh-dashboard",
                service_map,
                prefer(overrides.get("wazuh_dashboard_username"), "admin"),
                wazuh_dashboard_password,
                build_source_label(wazuh_dashboard_password, wazuh_dashboard_password_source),
                "Interactive SOC dashboard login.",
            ),
            build_service_entry(
                "prometheus",
                service_map,
                "none",
                "",
                "none",
            ),
            build_service_entry(
                "alertmanager",
                service_map,
                "none",
                "",
                "none",
            ),
            build_service_entry(
                "blackbox-exporter",
                service_map,
                "none",
                "",
                "none",
            ),
            build_service_entry(
                "wazuh-api",
                service_map,
                prefer(overrides.get("wazuh_api_username"), "wazuh-wui"),
                wazuh_api_password,
                build_source_label(wazuh_api_password, wazuh_api_password_source),
            ),
            build_service_entry(
                "wazuh-indexer",
                service_map,
                prefer(overrides.get("wazuh_indexer_username"), "admin"),
                wazuh_indexer_password,
                build_source_label(wazuh_indexer_password, wazuh_indexer_password_source),
            ),
            build_service_entry(
                "pihole-admin",
                service_map,
                "none",
                pihole_password,
                build_source_label(pihole_password, pihole_password_source),
            ),
            build_service_entry(
                "pihole-dns",
                service_map,
                "none",
                "",
                "none",
            ),
            build_service_entry(
                "mitmproxy-ui",
                service_map,
                "none",
                "",
                "none",
            ),
            build_service_entry(
                "mitmproxy-proxy",
                service_map,
                "none",
                "",
                "none",
            ),
            build_service_entry(
                "sensor-ssh",
                service_map,
                prefer(overrides.get("sensor_ssh_username"), "subash"),
                sensor_ssh_password,
                build_source_label(sensor_ssh_password, sensor_ssh_password_source),
            ),
        ],
        "extras": [
            build_extra_entry(
                "Sensor sudo",
                "sudo on 192.168.1.6",
                prefer(overrides.get("sensor_ssh_username"), "subash"),
                sensor_sudo_password,
                build_source_label(sensor_sudo_password, sensor_sudo_password_source),
                "Used for privileged commands on the Ubuntu sensor VM.",
            ),
            build_extra_entry(
                "Wazuh dashboard service user",
                "wazuh-docker-stack/single-node/config/wazuh_dashboard/wazuh.yml",
                "kibanaserver",
                wazuh_dashboard_service_password,
                build_source_label(
                    wazuh_dashboard_service_password,
                    wazuh_dashboard_service_password_source,
                ),
                "Internal dashboard service credential used by the Wazuh dashboard container.",
            ),
            build_extra_entry(
                "Brevo SMTP relay",
                smtp_smarthost or "smtp-relay.brevo.com:587",
                smtp_username or "not available",
                smtp_password,
                build_source_label(
                    smtp_password,
                    "secrets/brevo_smtp_key.txt",
                ),
                f"Sender: {smtp_from or 'not available'} | Stack email target: {stack_email_to or 'not available'}",
            ),
            build_extra_entry(
                "Monitoring host env summary",
                str(ROOT_ENV_PATH.relative_to(REPO_ROOT)) if ROOT_ENV_PATH.exists() else ".env",
                "n/a",
                "file present" if ROOT_ENV_PATH.exists() else "missing",
                ".env",
                "Root monitoring stack local environment file state.",
            ),
        ],
    }
    launcher_payload = build_launcher_payload(payload, catalog)

    PRIVATE_ROOT.mkdir(parents=True, exist_ok=True)
    OUTPUT_JSON.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    OUTPUT_HTML.write_text(build_html(payload), encoding="utf-8")
    LAUNCHER_JSON.write_text(json.dumps(launcher_payload, indent=2), encoding="utf-8")
    LAUNCHER_HTML.write_text(build_launcher_html(payload, launcher_payload), encoding="utf-8")
    print(f"Generated {OUTPUT_HTML}")
    print(f"Generated {OUTPUT_JSON}")
    print(f"Generated {LAUNCHER_HTML}")
    print(f"Generated {LAUNCHER_JSON}")


if __name__ == "__main__":
    main()
