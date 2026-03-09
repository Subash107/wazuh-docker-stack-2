#!/usr/bin/env python3
import datetime
import ipaddress
import json
import os
import re
import time
import traceback
import urllib.error
import urllib.request


ALERTMANAGER_URL = os.getenv("ALERTMANAGER_URL", "http://alertmanager:9093/api/v2/alerts")
WAZUH_ALERT_FILE = os.getenv("WAZUH_ALERT_FILE", "/wazuh-logs/alerts/alerts.json")
MIN_RULE_LEVEL = int(os.getenv("MIN_RULE_LEVEL", "10"))
START_FROM_END = os.getenv("START_FROM_END", "true").lower() == "true"
POLL_INTERVAL = float(os.getenv("POLL_INTERVAL", "1"))
WAZUH_DASHBOARD_URL = os.getenv("WAZUH_DASHBOARD_URL", "http://192.168.1.3:5601").rstrip("/")
EXCLUDED_RULE_IDS = {
    item.strip()
    for item in os.getenv("EXCLUDED_RULE_IDS", "17102,2902,2904,60776").split(",")
    if item.strip()
}
EXCLUDED_RULE_GROUPS = {
    item.strip().lower()
    for item in os.getenv("EXCLUDED_RULE_GROUPS", "sca").split(",")
    if item.strip()
}
DEDUP_WINDOW_SECONDS = int(os.getenv("DEDUP_WINDOW_SECONDS", "900"))
SURICATA_MAX_ALERT_SEVERITY = int(os.getenv("SURICATA_MAX_ALERT_SEVERITY", "2"))
SURICATA_EXCLUDED_CATEGORIES = {
    item.strip().lower()
    for item in os.getenv("SURICATA_EXCLUDED_CATEGORIES", "Not Suspicious Traffic").split(",")
    if item.strip()
}
SURICATA_EXCLUDED_SIGNATURE_IDS = {
    item.strip()
    for item in os.getenv("SURICATA_EXCLUDED_SIGNATURE_IDS", "").split(",")
    if item.strip()
}
GEOLOOKUP_ENABLED = os.getenv("GEOLOOKUP_ENABLED", "true").lower() == "true"
GEOLOOKUP_URL_TEMPLATE = os.getenv("GEOLOOKUP_URL_TEMPLATE", "https://ipwho.is/{ip}")
GEOLOOKUP_TIMEOUT_SECONDS = float(os.getenv("GEOLOOKUP_TIMEOUT_SECONDS", "5"))
FULL_LOG_MAX_LENGTH = int(os.getenv("FULL_LOG_MAX_LENGTH", "2000"))
CORRELATION_WINDOW_SECONDS = int(os.getenv("CORRELATION_WINDOW_SECONDS", "3600"))
CORRELATION_TIMELINE_LIMIT = int(os.getenv("CORRELATION_TIMELINE_LIMIT", "6"))
CORRELATION_HISTORY_LIMIT = int(os.getenv("CORRELATION_HISTORY_LIMIT", "100"))
RECENT_ALERTS = {}
GEO_CACHE = {}
EVENT_HISTORY = {}


def parse_timestamp_dt(raw_ts):
    if not raw_ts:
        return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(raw_ts, fmt)
        except ValueError:
            pass
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def parse_timestamp(raw_ts):
    return parse_timestamp_dt(raw_ts).isoformat()


def normalize_text(value, default="unknown"):
    if value in (None, ""):
        return default
    text = re.sub(r"\s+", " ", str(value)).strip()
    return text or default


def get_source_ip(alert):
    data = alert.get("data") or {}
    for key in ("srcip", "src_ip", "source_ip", "ip"):
        value = data.get(key)
        if value:
            return str(value)
    for key in ("srcip", "src_ip", "source_ip"):
        value = alert.get(key)
        if value:
            return str(value)
    return "unknown"


def get_data_field(alert, *keys):
    data = alert.get("data") or {}
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return str(value)
    return ""


def get_nested_value(value, *path):
    current = value
    for part in path:
        if isinstance(current, dict):
            current = current.get(part)
        elif isinstance(current, list) and isinstance(part, int):
            if part >= len(current):
                return None
            current = current[part]
        else:
            return None
    return current


def get_rule_groups(rule):
    groups = rule.get("groups") or []
    if isinstance(groups, list):
        result = []
        for item in groups:
            cleaned = normalize_text(item, default="")
            if cleaned:
                result.append(cleaned)
        return result
    cleaned = normalize_text(groups, default="")
    return [cleaned] if cleaned else []


def to_csv(value):
    if isinstance(value, list):
        return ",".join(str(item) for item in value if item)
    if value:
        return str(value)
    return ""


def safe_int(value, default=0):
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return default


def parse_ip(value):
    if not value or value == "unknown":
        return None
    try:
        return ipaddress.ip_address(str(value))
    except ValueError:
        return None


def format_endpoint(ip, port):
    clean_ip = normalize_text(ip, default="unknown")
    clean_port = normalize_text(port, default="unknown")
    if clean_ip == "unknown" and clean_port == "unknown":
        return "unknown"
    if clean_port == "unknown":
        return clean_ip
    return f"{clean_ip}:{clean_port}"


def get_mitre_fields(rule):
    mitre = rule.get("mitre") or {}
    return {
        "ids": to_csv(mitre.get("id")),
        "tactics": to_csv(mitre.get("tactic")),
        "techniques": to_csv(mitre.get("technique")),
    }


def parse_listening_ports(full_log):
    entries = []
    seen = set()

    for line in full_log.splitlines():
        parts = line.strip().split()
        if len(parts) < 2 or parts[0] not in {"tcp", "tcp6", "udp", "udp6"}:
            continue

        endpoint = parts[1]
        if ":" not in endpoint:
            continue

        bind_ip, port = endpoint.rsplit(":", 1)
        if not port.isdigit():
            continue

        proto = parts[0]
        key = (proto, bind_ip, port)
        if key in seen:
            continue
        seen.add(key)
        entries.append({"proto": proto, "ip": bind_ip, "port": port})

    return entries


def extract_from_full_log(full_log):
    extracted = {}

    firewall_match = re.search(
        r"\bSRC=(?P<srcip>\S+)\b.*\bDST=(?P<dstip>\S+)\b.*\bSPT=(?P<srcport>\d+)\b.*\bDPT=(?P<dstport>\d+)\b",
        full_log,
    )
    if firewall_match:
        extracted.update({key: value for key, value in firewall_match.groupdict().items() if value})

    ssh_match = re.search(
        r"\bfrom (?P<srcip>\d{1,3}(?:\.\d{1,3}){3}) port (?P<srcport>\d+)\b",
        full_log,
    )
    if ssh_match:
        for key, value in ssh_match.groupdict().items():
            extracted.setdefault(key, value)

    generic_endpoint = re.search(
        r"\b(?P<srcip>\d{1,3}(?:\.\d{1,3}){3}):(?P<srcport>\d+)\b",
        full_log,
    )
    if generic_endpoint:
        for key, value in generic_endpoint.groupdict().items():
            extracted.setdefault(key, value)

    return extracted


def get_suricata_details(alert):
    data = alert.get("data") or {}
    queries = get_nested_value(data, "dns", "query")
    dns_query = ""
    if isinstance(queries, list):
        for item in queries:
            if not isinstance(item, dict):
                continue
            rrname = item.get("rrname")
            if rrname:
                dns_query = str(rrname)
                break

    http_hostname = to_csv(get_nested_value(data, "http", "hostname"))
    http_url = to_csv(get_nested_value(data, "http", "url"))
    tls_sni = to_csv(get_nested_value(data, "tls", "sni"))
    signature = to_csv(get_nested_value(data, "alert", "signature"))
    category = to_csv(get_nested_value(data, "alert", "category"))
    signature_id = to_csv(get_nested_value(data, "alert", "signature_id"))
    flow_id = to_csv(data.get("flow_id"))
    event_type = to_csv(data.get("event_type"))
    app_proto = to_csv(data.get("app_proto"))
    direction = to_csv(data.get("direction"))
    severity = safe_int(get_nested_value(data, "alert", "severity"), default=0)
    indicator = dns_query or tls_sni or http_hostname or http_url or "not available"
    return {
        "signature": signature or "not available",
        "category": category or "not available",
        "signature_id": signature_id or "unknown",
        "severity": severity,
        "flow_id": flow_id or "unknown",
        "event_type": event_type or "unknown",
        "app_proto": app_proto or "unknown",
        "direction": direction or "unknown",
        "dns_query": dns_query or "not available",
        "http_hostname": http_hostname or "not available",
        "http_url": http_url or "not available",
        "tls_sni": tls_sni or "not available",
        "indicator": indicator,
    }


def is_suricata_alert(rule, location):
    groups = rule.get("groups") or []
    if isinstance(groups, list) and "suricata" in groups:
        return True
    return "suricata" in str(location).lower()


def classify_event(rule_groups, suricata_alert, location, decoder_name):
    groups = {item.lower() for item in rule_groups}
    location_text = str(location).lower()
    decoder_text = str(decoder_name).lower()

    if suricata_alert:
        return "Suricata IDS", "Network intrusion", "network"
    if "sca" in groups:
        return "Wazuh SCA", "Configuration drift", "host"
    if "pam" in groups or "sudo" in groups or "login_day" in groups or "sshd" in decoder_text:
        return "Wazuh agent", "Authentication or access activity", "access"
    if "firewall" in groups or "netfilter" in location_text:
        return "Wazuh agent", "Network activity", "network"
    return "Wazuh agent", "Host alert", "host"


def detect_tool_name(rule_groups, suricata_alert, location, decoder_name, description, full_log):
    groups = {item.lower() for item in rule_groups}
    haystack = " ".join(
        normalize_text(item, default="")
        for item in (location, decoder_name, description, full_log[:300])
        if item
    ).lower()

    if suricata_alert:
        return "Suricata IDS"
    if "cowrie" in haystack:
        return "Cowrie honeypot"
    if "opencanary" in haystack or "canary" in haystack:
        return "OpenCanary"
    if "maltrail" in haystack:
        return "Maltrail"
    if "mitmproxy" in haystack:
        return "mitmproxy"
    if "sshd" in haystack or "login_day" in groups or "pam" in groups:
        return "SSH or auth logs"
    if "sudo" in groups or "sudo" in haystack:
        return "sudo"
    if "firewall" in groups or "netfilter" in haystack:
        return "Firewall"
    if "ossec" in groups or "wazuh" in haystack:
        return "Wazuh agent"
    return "Wazuh alert stream"


def should_forward_suricata(level, suricata, is_suricata):
    if not is_suricata:
        return False
    if suricata["event_type"] != "alert":
        return False
    if suricata["signature_id"] in SURICATA_EXCLUDED_SIGNATURE_IDS:
        return False
    if suricata["category"].lower() in SURICATA_EXCLUDED_CATEGORIES:
        return False
    if suricata["severity"] <= 0:
        return False
    if level >= MIN_RULE_LEVEL:
        return True
    return suricata["severity"] <= SURICATA_MAX_ALERT_SEVERITY


def classify_severity(level, suricata_alert, suricata):
    if suricata_alert and suricata["severity"] == 1:
        return "critical"
    if level >= 12:
        return "critical"
    if (suricata_alert and suricata["severity"] == 2) or level >= 9:
        return "high"
    return "warning"


def build_subject_endpoint(network, is_suricata):
    if is_suricata and network["remote_ip"] != "unknown":
        return network["remote_ip"], network["remote_port"]
    return network["observed_ip"], network["observed_port"]


def build_origin_endpoint(network):
    if network["src_ip"] != "unknown":
        return network["src_ip"], network["src_port"]
    return network["remote_ip"], network["remote_port"]


def build_action_hint(severity, event_category, suricata_alert, network, indicator):
    remote_endpoint = format_endpoint(network["remote_ip"], network["remote_port"])
    local_endpoint = format_endpoint(network["local_ip"], network["local_port"])

    if suricata_alert:
        return (
            f"Review traffic from {remote_endpoint} to {local_endpoint}, validate the indicator "
            f"'{indicator}', and block or isolate the source if the activity is malicious."
        )
    if event_category == "Authentication or access activity":
        return (
            "Review recent login and sudo activity for the affected account, confirm the source "
            "IP and user are expected, and rotate credentials if the activity is suspicious."
        )
    if severity == "critical":
        return "Investigate immediately and confirm whether this activity is expected."
    return "Review the device and source context to determine whether this is expected."


def build_email_subject(event_category, agent_name, suricata_alert, network, subject_ip, subject_port, rule_id):
    if suricata_alert:
        focus = (
            f"{format_endpoint(network['remote_ip'], network['remote_port'])} -> "
            f"{format_endpoint(network['local_ip'], network['local_port'])}"
        )
    else:
        focus = format_endpoint(subject_ip, subject_port)

    if focus == "unknown":
        return f"{event_category} on {agent_name} | Rule {rule_id}"
    return f"{event_category} on {agent_name} | {focus} | Rule {rule_id}"


def build_dashboard_search_hint(agent_name, event_id, rule_id):
    return (
        f"Search agent '{agent_name}' with event ID '{event_id}'. "
        f"If needed, search rule ID '{rule_id}' for related activity."
    )


def build_geo_result(
    location="unknown",
    city="unknown",
    region="unknown",
    country="unknown",
    coordinates="unknown",
    org="unknown",
    isp="unknown",
    domain="unknown",
    asn="unknown",
):
    return {
        "location": location,
        "city": city,
        "region": region,
        "country": country,
        "coordinates": coordinates,
        "org": org,
        "isp": isp,
        "domain": domain,
        "asn": asn,
    }


def join_location_parts(*parts):
    cleaned = [str(part).strip() for part in parts if part and str(part).strip() and str(part).strip().lower() != "unknown"]
    return ", ".join(cleaned) if cleaned else "unknown"


def lookup_ip_geolocation(remote_ip):
    if remote_ip in GEO_CACHE:
        return GEO_CACHE[remote_ip]

    parsed_ip = parse_ip(remote_ip)
    if not GEOLOOKUP_ENABLED:
        result = build_geo_result(location="lookup disabled")
        GEO_CACHE[remote_ip] = result
        return result

    if parsed_ip is None:
        result = build_geo_result(location="unknown")
        GEO_CACHE[remote_ip] = result
        return result

    if not getattr(parsed_ip, "is_global", False):
        result = build_geo_result(location="not available for non-public IP")
        GEO_CACHE[remote_ip] = result
        return result

    url = GEOLOOKUP_URL_TEMPLATE.format(ip=remote_ip)
    try:
        with urllib.request.urlopen(url, timeout=GEOLOOKUP_TIMEOUT_SECONDS) as response:
            data = json.loads(response.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        result = build_geo_result(location="lookup unavailable")
        GEO_CACHE[remote_ip] = result
        return result

    if not data.get("success", True):
        result = build_geo_result(location="lookup unavailable")
        GEO_CACHE[remote_ip] = result
        return result

    city = to_csv(data.get("city")) or "unknown"
    region = to_csv(data.get("region")) or "unknown"
    country = to_csv(data.get("country")) or "unknown"
    latitude = data.get("latitude")
    longitude = data.get("longitude")
    connection = data.get("connection") or {}
    coordinates = "unknown"
    if latitude not in (None, "") and longitude not in (None, ""):
        coordinates = f"{latitude}, {longitude}"

    result = build_geo_result(
        location=join_location_parts(city, region, country),
        city=city,
        region=region,
        country=country,
        coordinates=coordinates,
        org=to_csv(connection.get("org")) or "unknown",
        isp=to_csv(connection.get("isp")) or "unknown",
        domain=to_csv(connection.get("domain")) or "unknown",
        asn=str(connection.get("asn") or "unknown"),
    )
    GEO_CACHE[remote_ip] = result
    return result


def describe_network_location(remote_ip, agent_ip):
    remote = parse_ip(remote_ip)
    agent = parse_ip(agent_ip)

    if remote is None:
        return "unknown"
    if agent and remote == agent:
        return "same device"
    if remote.is_loopback:
        return "loopback"
    if remote.is_link_local:
        return "link-local"
    if remote.is_multicast:
        return "multicast"
    if remote.is_unspecified:
        return "unspecified"
    if remote.is_reserved:
        return "reserved/test network"
    if remote.is_private:
        if (
            agent
            and remote.version == agent.version
            and remote.version == 4
            and str(remote).split(".")[:3] == str(agent).split(".")[:3]
        ):
            return "same local subnet"
        return "private network"
    if getattr(remote, "is_global", False):
        return "public internet"
    return "special network"


def build_network_details(alert, agent_ip, src_ip, full_log):
    extracted = extract_from_full_log(full_log)
    listeners = parse_listening_ports(full_log)

    src_port = get_data_field(alert, "srcport", "src_port", "source_port", "sport")
    dst_ip = get_data_field(alert, "dstip", "dst_ip", "dest_ip", "destination_ip")
    dst_port = get_data_field(alert, "dstport", "dst_port", "dest_port", "destination_port", "dport")
    protocol = get_data_field(alert, "protocol", "proto", "protocol_name")

    if not src_port:
        src_port = extracted.get("srcport", "")
    if not dst_ip:
        dst_ip = extracted.get("dstip", "")
    if not dst_port:
        dst_port = extracted.get("dstport", "")
    if src_ip == "unknown" and extracted.get("srcip"):
        src_ip = extracted["srcip"]

    if src_ip != "unknown" and not dst_ip:
        dst_ip = agent_ip

    listening_ports = ", ".join(
        f"{entry['proto']}/{entry['port']}@{entry['ip']}" for entry in listeners[:10]
    )

    if listeners:
        unique_ips = list(dict.fromkeys(entry["ip"] for entry in listeners))
        if src_ip == "unknown":
            observed_ip = unique_ips[0] if len(unique_ips) == 1 else "multiple"
        else:
            observed_ip = src_ip

        unique_ports = list(dict.fromkeys(entry["port"] for entry in listeners))
        if src_port:
            observed_port = src_port
        elif dst_port:
            observed_port = dst_port
        else:
            observed_port = unique_ports[0] if len(unique_ports) == 1 else "multi"
    else:
        observed_ip = src_ip if src_ip != "unknown" else (dst_ip or agent_ip)
        observed_port = src_port or dst_port or "unknown"

    if src_ip != "unknown" and src_port:
        network_context = f"{src_ip}:{src_port} -> {dst_ip or agent_ip}:{dst_port or 'unknown'}"
    elif listeners:
        network_context = listening_ports
    elif src_ip != "unknown":
        network_context = f"{src_ip} -> {dst_ip or agent_ip}"
    else:
        network_context = "unknown"

    if src_ip != "unknown" and src_ip == agent_ip:
        local_ip = src_ip
        local_port = src_port or "unknown"
        remote_ip = dst_ip or "unknown"
        remote_port = dst_port or "unknown"
    elif dst_ip and dst_ip == agent_ip:
        local_ip = dst_ip
        local_port = dst_port or "unknown"
        remote_ip = src_ip
        remote_port = src_port or "unknown"
    elif src_ip != "unknown" and dst_ip:
        local_ip = src_ip
        local_port = src_port or "unknown"
        remote_ip = dst_ip
        remote_port = dst_port or "unknown"
    else:
        local_ip = agent_ip
        local_port = dst_port or src_port or "unknown"
        remote_ip = "unknown"
        remote_port = "unknown"

    return {
        "src_ip": src_ip,
        "src_port": src_port or "unknown",
        "dst_ip": dst_ip or agent_ip,
        "dst_port": dst_port or "unknown",
        "protocol": protocol or "unknown",
        "observed_ip": observed_ip or "unknown",
        "observed_port": observed_port or "unknown",
        "listening_ports": listening_ports or "not available",
        "network_context": network_context,
        "local_ip": local_ip,
        "local_port": local_port,
        "remote_ip": remote_ip,
        "remote_port": remote_port,
    }


def build_correlation_key(origin_ip, indicator):
    if origin_ip and origin_ip != "unknown":
        return f"ip:{origin_ip}"
    clean_indicator = normalize_text(indicator, default="")
    if clean_indicator and clean_indicator != "not available":
        return f"indicator:{clean_indicator.lower()}"
    return ""


def prune_event_history(now=None):
    if CORRELATION_WINDOW_SECONDS <= 0:
        EVENT_HISTORY.clear()
        return

    if now is None:
        now = time.time()

    cutoff = now - CORRELATION_WINDOW_SECONDS
    for key in list(EVENT_HISTORY.keys()):
        filtered = [item for item in EVENT_HISTORY[key] if item["timestamp_unix"] >= cutoff]
        if filtered:
            EVENT_HISTORY[key] = filtered[-CORRELATION_HISTORY_LIMIT:]
        else:
            EVENT_HISTORY.pop(key, None)


def build_timeline_entry(event):
    level_text = f"level {event['level']}"
    endpoint_text = event["origin_endpoint"]
    target_text = event["target_endpoint"]
    if endpoint_text != "unknown" and target_text != "unknown":
        path_text = f"{endpoint_text} -> {target_text}"
    elif endpoint_text != "unknown":
        path_text = endpoint_text
    else:
        path_text = target_text

    return (
        f"{event['timestamp_text']} | {event['tool']} | {event['severity']} ({level_text}) | "
        f"{event['description']} | {path_text}"
    )


def record_event_for_correlation(alert):
    if CORRELATION_WINDOW_SECONDS <= 0:
        return

    rule = alert.get("rule") or {}
    rule_id = str(rule.get("id", "unknown"))
    rule_groups = get_rule_groups(rule)
    if rule_id in EXCLUDED_RULE_IDS:
        return
    if {item.lower() for item in rule_groups} & EXCLUDED_RULE_GROUPS:
        return

    agent = alert.get("agent") or {}
    agent_name = str(agent.get("name", "unknown-device"))
    agent_ip = str(agent.get("ip", "unknown"))
    src_ip = get_source_ip(alert)
    description = normalize_text(rule.get("description", "Wazuh alert"))
    location = str(alert.get("location", "unknown"))
    decoder_name = normalize_text(
        get_nested_value(alert, "decoder", "name")
        or get_nested_value(alert, "decoder", "parent")
    )
    event_id = str(alert.get("id", "unknown"))
    event_time = parse_timestamp_dt(alert.get("timestamp"))
    full_log = str(alert.get("full_log", ""))[:FULL_LOG_MAX_LENGTH]
    network = build_network_details(alert, agent_ip, src_ip, full_log)
    suricata = get_suricata_details(alert)
    suricata_alert = is_suricata_alert(rule, location)
    severity = classify_severity(int(rule.get("level", 0)), suricata_alert, suricata)
    tool = detect_tool_name(rule_groups, suricata_alert, location, decoder_name, description, full_log)
    origin_ip, origin_port = build_origin_endpoint(network)
    key = build_correlation_key(origin_ip, suricata["indicator"])
    if not key:
        return

    prune_event_history(event_time.timestamp())
    EVENT_HISTORY.setdefault(key, []).append(
        {
            "event_id": event_id,
            "timestamp_unix": event_time.timestamp(),
            "timestamp_text": event_time.isoformat(),
            "agent": agent_name,
            "tool": tool,
            "description": description,
            "rule_id": rule_id,
            "level": int(rule.get("level", 0)),
            "severity": severity,
            "location": location,
            "origin_endpoint": format_endpoint(origin_ip, origin_port),
            "target_endpoint": format_endpoint(network["local_ip"], network["local_port"]),
        }
    )
    EVENT_HISTORY[key] = EVENT_HISTORY[key][-CORRELATION_HISTORY_LIMIT:]


def build_correlation_context(origin_ip, indicator):
    empty = {
        "summary": "1 related event in the recent window on 1 tool",
        "first_seen": "unknown",
        "last_seen": "unknown",
        "repeat_count": "1",
        "tool_count": "1",
        "tools": "current alert only",
        "agents": "unknown",
        "log_sources": "unknown",
        "recent_activity": "No additional related events in the current window.",
        "window_minutes": str(max(1, round(CORRELATION_WINDOW_SECONDS / 60))),
    }
    if CORRELATION_WINDOW_SECONDS <= 0:
        return empty

    key = build_correlation_key(origin_ip, indicator)
    if not key:
        return empty

    prune_event_history()
    history = EVENT_HISTORY.get(key, [])
    if not history:
        return empty

    history = sorted(history, key=lambda item: item["timestamp_unix"])
    tools = list(dict.fromkeys(item["tool"] for item in history if item["tool"]))
    agents = list(dict.fromkeys(item["agent"] for item in history if item["agent"]))
    log_sources = list(dict.fromkeys(item["location"] for item in history if item["location"]))
    timeline = history[-CORRELATION_TIMELINE_LIMIT:]

    return {
        "summary": (
            f"{len(history)} related events in the last "
            f"{max(1, round(CORRELATION_WINDOW_SECONDS / 60))} minutes "
            f"across {len(tools) or 1} tool(s)"
        ),
        "first_seen": history[0]["timestamp_text"],
        "last_seen": history[-1]["timestamp_text"],
        "repeat_count": str(len(history)),
        "tool_count": str(len(tools) or 1),
        "tools": ", ".join(tools) if tools else "current alert only",
        "agents": ", ".join(agents) if agents else "unknown",
        "log_sources": ", ".join(log_sources) if log_sources else "unknown",
        "recent_activity": "\n".join(build_timeline_entry(item) for item in timeline),
        "window_minutes": str(max(1, round(CORRELATION_WINDOW_SECONDS / 60))),
    }


def prune_recent_alerts(now):
    if DEDUP_WINDOW_SECONDS <= 0:
        return

    expired_keys = [
        key for key, timestamp in RECENT_ALERTS.items() if now - timestamp >= DEDUP_WINDOW_SECONDS
    ]
    for key in expired_keys:
        RECENT_ALERTS.pop(key, None)


def dedup_key(payload):
    labels = payload[0]["labels"]
    annotations = payload[0]["annotations"]
    return (
        labels["wazuh_rule_id"],
        labels["agent"],
        labels["srcip"],
        labels.get("dstip", ""),
        labels.get("dstport", ""),
        labels.get("subject_ip", ""),
        labels.get("subject_port", ""),
        labels["location"],
        annotations["description"],
        annotations.get("suricata_signature_id", ""),
        annotations.get("network_context", ""),
    )


def should_skip_duplicate(payload):
    if DEDUP_WINDOW_SECONDS <= 0:
        return False

    now = time.time()
    prune_recent_alerts(now)
    key = dedup_key(payload)
    last_seen = RECENT_ALERTS.get(key)
    if last_seen and now - last_seen < DEDUP_WINDOW_SECONDS:
        return True
    return False


def remember_alert(payload):
    if DEDUP_WINDOW_SECONDS <= 0:
        return

    now = time.time()
    prune_recent_alerts(now)
    RECENT_ALERTS[dedup_key(payload)] = now


def to_alertmanager_payload(alert):
    rule = alert.get("rule") or {}
    level = int(rule.get("level", 0))

    agent = alert.get("agent") or {}
    agent_id = str(agent.get("id", "unknown"))
    agent_name = str(agent.get("name", "unknown-device"))
    agent_ip = str(agent.get("ip", "unknown"))
    src_ip = get_source_ip(alert)
    rule_id = str(rule.get("id", "unknown"))
    description = normalize_text(rule.get("description", "Wazuh threat detected"))
    location = str(alert.get("location", "unknown"))
    event_id = str(alert.get("id", "unknown"))
    event_time_utc = parse_timestamp(alert.get("timestamp"))
    full_log = str(alert.get("full_log", ""))[:FULL_LOG_MAX_LENGTH]
    groups = get_rule_groups(rule)
    groups_text = ",".join(groups) if groups else "unknown"
    mitre = get_mitre_fields(rule)
    network = build_network_details(alert, agent_ip, src_ip, full_log)
    suricata = get_suricata_details(alert)
    suricata_alert = is_suricata_alert(rule, location)
    manager_name = normalize_text(get_nested_value(alert, "manager", "name"))
    decoder_name = normalize_text(
        get_nested_value(alert, "decoder", "name")
        or get_nested_value(alert, "decoder", "parent")
    )
    if not should_forward_suricata(level, suricata, suricata_alert) and level < MIN_RULE_LEVEL:
        return None

    severity = classify_severity(level, suricata_alert, suricata)
    subject_ip, subject_port = build_subject_endpoint(network, suricata_alert)
    origin_ip, origin_port = build_origin_endpoint(network)
    correlation = build_correlation_context(origin_ip, suricata["indicator"])
    dashboard_url = WAZUH_DASHBOARD_URL or ""
    remote_location = describe_network_location(network["remote_ip"], agent_ip)
    remote_geo = lookup_ip_geolocation(network["remote_ip"])
    origin_location = describe_network_location(origin_ip, agent_ip)
    origin_geo = lookup_ip_geolocation(origin_ip)
    threat_source, event_category, threat_scope = classify_event(
        groups, suricata_alert, location, decoder_name
    )
    action_hint = build_action_hint(
        severity, event_category, suricata_alert, network, suricata["indicator"]
    )
    email_subject = build_email_subject(
        event_category, agent_name, suricata_alert, network, subject_ip, subject_port, rule_id
    )
    if suricata_alert:
        summary = (
            f"Network threat on {agent_name} | "
            f"{format_endpoint(network['remote_ip'], network['remote_port'])} -> "
            f"{format_endpoint(network['local_ip'], network['local_port'])}"
        )
    else:
        summary = f"{description} on {agent_name} | observed {format_endpoint(subject_ip, subject_port)}"

    return [
        {
            "labels": {
                "alertname": "WazuhThreatDetected",
                "severity": severity,
                "agent": agent_name,
                "agent_ip": agent_ip,
                "srcip": src_ip,
                "srcport": network["src_port"],
                "dstip": network["dst_ip"],
                "dstport": network["dst_port"],
                "subject_ip": subject_ip,
                "subject_port": subject_port,
                "local_ip": network["local_ip"],
                "local_port": network["local_port"],
                "remote_ip": network["remote_ip"],
                "remote_port": network["remote_port"],
                "wazuh_rule_id": rule_id,
                "wazuh_level": str(level),
                "location": location,
                "event_id": event_id,
            },
            "annotations": {
                "email_subject": email_subject,
                "summary": summary,
                "description": description,
                "event_id": event_id,
                "event_time_utc": event_time_utc,
                "agent_id": agent_id,
                "manager_name": manager_name,
                "decoder_name": decoder_name,
                "threat_source": threat_source,
                "event_category": event_category,
                "threat_scope": threat_scope,
                "rule_firedtimes": str(rule.get("firedtimes", "")),
                "correlation_summary": correlation["summary"],
                "correlation_first_seen_utc": correlation["first_seen"],
                "correlation_last_seen_utc": correlation["last_seen"],
                "correlation_repeat_count": correlation["repeat_count"],
                "correlation_tool_count": correlation["tool_count"],
                "correlation_tools": correlation["tools"],
                "correlation_agents": correlation["agents"],
                "correlation_log_sources": correlation["log_sources"],
                "correlation_recent_activity": correlation["recent_activity"],
                "correlation_window_minutes": correlation["window_minutes"],
                "rule_groups": groups_text,
                "mitre_ids": mitre["ids"],
                "mitre_tactics": mitre["tactics"],
                "mitre_techniques": mitre["techniques"],
                "protocol": network["protocol"],
                "application_protocol": suricata["app_proto"],
                "traffic_direction": suricata["direction"],
                "source_ip": network["src_ip"],
                "source_port": network["src_port"],
                "origin_ip": origin_ip,
                "origin_port": origin_port,
                "origin_endpoint": format_endpoint(origin_ip, origin_port),
                "origin_location_scope": origin_location,
                "origin_geo_location": origin_geo["location"],
                "origin_geo_city": origin_geo["city"],
                "origin_geo_region": origin_geo["region"],
                "origin_geo_country": origin_geo["country"],
                "origin_geo_coordinates": origin_geo["coordinates"],
                "origin_geo_org": origin_geo["org"],
                "origin_geo_isp": origin_geo["isp"],
                "origin_geo_domain": origin_geo["domain"],
                "origin_geo_asn": origin_geo["asn"],
                "destination_ip": network["dst_ip"],
                "destination_port": network["dst_port"],
                "observed_ip": network["observed_ip"],
                "observed_port": network["observed_port"],
                "local_ip": network["local_ip"],
                "local_port": network["local_port"],
                "remote_ip": network["remote_ip"],
                "remote_port": network["remote_port"],
                "listening_ports": network["listening_ports"],
                "network_context": network["network_context"],
                "remote_location": remote_location,
                "geo_location": remote_geo["location"],
                "geo_city": remote_geo["city"],
                "geo_region": remote_geo["region"],
                "geo_country": remote_geo["country"],
                "geo_coordinates": remote_geo["coordinates"],
                "geo_org": remote_geo["org"],
                "geo_isp": remote_geo["isp"],
                "geo_domain": remote_geo["domain"],
                "geo_asn": remote_geo["asn"],
                "log_source": location,
                "suricata_signature": suricata["signature"],
                "suricata_signature_id": suricata["signature_id"],
                "suricata_category": suricata["category"],
                "suricata_severity": str(suricata["severity"] or ""),
                "suricata_event_type": suricata["event_type"],
                "suricata_flow_id": suricata["flow_id"],
                "dns_query": suricata["dns_query"],
                "http_hostname": suricata["http_hostname"],
                "http_url": suricata["http_url"],
                "tls_sni": suricata["tls_sni"],
                "network_indicator": suricata["indicator"],
                "dashboard_url": dashboard_url,
                "dashboard_search_hint": build_dashboard_search_hint(agent_name, event_id, rule_id),
                "action_hint": action_hint,
                "full_log": full_log,
            },
            "startsAt": event_time_utc,
        }
    ]


def post_to_alertmanager(payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        ALERTMANAGER_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        if response.status not in (200, 202):
            raise RuntimeError(f"Unexpected status code from Alertmanager: {response.status}")


def process_line(line):
    line = line.strip()
    if not line:
        return
    try:
        alert = json.loads(line)
    except json.JSONDecodeError:
        return

    record_event_for_correlation(alert)
    payload = to_alertmanager_payload(alert)
    if not payload:
        return

    labels = payload[0]["labels"]
    annotations = payload[0]["annotations"]
    if labels["wazuh_rule_id"] in EXCLUDED_RULE_IDS:
        print(
            "suppressed"
            f" reason=excluded_rule_id"
            f" rule_id={labels['wazuh_rule_id']}"
            f" agent={labels['agent']}",
            flush=True,
        )
        return

    rule_groups = {
        item.strip().lower()
        for item in annotations.get("rule_groups", "").split(",")
        if item.strip()
    }
    excluded_groups = sorted(rule_groups & EXCLUDED_RULE_GROUPS)
    if excluded_groups:
        print(
            "suppressed"
            f" reason=excluded_rule_group"
            f" groups={','.join(excluded_groups)}"
            f" rule_id={labels['wazuh_rule_id']}"
            f" agent={labels['agent']}",
            flush=True,
        )
        return

    if should_skip_duplicate(payload):
        print(
            "suppressed"
            f" reason=dedup_window"
            f" rule_id={labels['wazuh_rule_id']}"
            f" agent={labels['agent']}"
            f" srcip={labels['srcip']}",
            flush=True,
        )
        return

    try:
        post_to_alertmanager(payload)
        remember_alert(payload)
        print(
            "forwarded"
            f" rule_id={labels['wazuh_rule_id']}"
            f" level={labels['wazuh_level']}"
            f" agent={labels['agent']}"
            f" srcip={labels['srcip']}",
            flush=True,
        )
    except (urllib.error.URLError, RuntimeError) as exc:
        print(f"post_failed error={exc}", flush=True)


def follow_file(path):
    while True:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                current_inode = os.fstat(f.fileno()).st_ino
                if START_FROM_END:
                    f.seek(0, os.SEEK_END)
                print(f"watching file={path} min_rule_level={MIN_RULE_LEVEL}", flush=True)
                while True:
                    line = f.readline()
                    if line:
                        process_line(line)
                        continue

                    time.sleep(POLL_INTERVAL)

                    try:
                        stat_result = os.stat(path)
                        if stat_result.st_ino != current_inode:
                            print("log_replaced reopening", flush=True)
                            break
                        if stat_result.st_size < f.tell():
                            print("log_truncated reopening", flush=True)
                            break
                    except FileNotFoundError:
                        print("log_missing reopening", flush=True)
                        break
        except FileNotFoundError:
            print(f"waiting_for_file path={path}", flush=True)
            time.sleep(2)
        except Exception as exc:
            print(f"forwarder_error error={exc}", flush=True)
            traceback.print_exc()
            time.sleep(2)


if __name__ == "__main__":
    print(
        f"startup alertmanager={ALERTMANAGER_URL}"
        f" wazuh_alert_file={WAZUH_ALERT_FILE}"
        f" min_rule_level={MIN_RULE_LEVEL}"
        f" dashboard_url={WAZUH_DASHBOARD_URL}",
        flush=True,
    )
    print(
        f"filters excluded_rule_ids={sorted(EXCLUDED_RULE_IDS)}"
        f" excluded_rule_groups={sorted(EXCLUDED_RULE_GROUPS)}"
        f" dedup_window_seconds={DEDUP_WINDOW_SECONDS}",
        flush=True,
    )
    print(
        f"suricata max_alert_severity={SURICATA_MAX_ALERT_SEVERITY}"
        f" excluded_categories={sorted(SURICATA_EXCLUDED_CATEGORIES)}"
        f" excluded_signature_ids={sorted(SURICATA_EXCLUDED_SIGNATURE_IDS)}",
        flush=True,
    )
    print(
        f"geolookup enabled={GEOLOOKUP_ENABLED}"
        f" timeout_seconds={GEOLOOKUP_TIMEOUT_SECONDS}"
        f" url_template={GEOLOOKUP_URL_TEMPLATE}"
        f" full_log_max_length={FULL_LOG_MAX_LENGTH}",
        flush=True,
    )
    print(
        f"correlation window_seconds={CORRELATION_WINDOW_SECONDS}"
        f" timeline_limit={CORRELATION_TIMELINE_LIMIT}"
        f" history_limit={CORRELATION_HISTORY_LIMIT}",
        flush=True,
    )
    follow_file(WAZUH_ALERT_FILE)
