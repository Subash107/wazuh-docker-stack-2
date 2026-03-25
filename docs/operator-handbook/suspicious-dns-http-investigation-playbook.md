# Suspicious DNS And HTTP Investigation Playbook

## Purpose

Use this playbook when a client on the lab network shows unusual DNS lookups, suspicious outbound web requests, or both.

This playbook assumes the current project layout:

- Pi-hole DNS on `192.168.1.6:53`
- mitmproxy web UI on `http://192.168.1.6:8083/#/flows`
- sensor VM at `192.168.1.6`
- monitoring host at `192.168.1.3`

## Trigger conditions

Start this playbook when any of these happen:

- Pi-hole query logs show unusual domains, spikes, or suspicious TLDs
- mitmproxy shows suspicious outbound requests or downloads
- Suricata raises HTTP, TLS, or DNS-related alerts
- Wazuh forwards a network or threat alert tied to DNS or web activity
- a user reports unexpected browser or application behavior

## Immediate goals

- identify the affected client
- determine which domains and URLs are involved
- decide whether the traffic is malicious, accidental, or expected testing
- contain the client or destination if needed

## First 5 minutes

1. Identify the client IP from the alert, Pi-hole, or mitmproxy.
2. Record the suspicious domains, hostnames, and URLs.
3. Check whether the traffic is still active.
4. Confirm whether the same client also triggered Suricata or Wazuh events.

## Triage checklist

- Are the queried domains random-looking, newly seen, or known bad?
- Is the client repeatedly contacting the same destination?
- Are there suspicious downloads, redirects, or authentication headers?
- Does the traffic involve uncommon user agents or unusual request timing?
- Did the client also contact one of the practice targets?

## Investigation pivots

### Pi-hole

Use Pi-hole to:

- review the DNS query log
- identify repeated lookups from the same client
- confirm whether the domain was blocked or resolved
- measure whether the client is generating unusual DNS volume

## mitmproxy

Use mitmproxy to:

- inspect HTTP and HTTPS flows from the same client
- review request paths, headers, payload size, and timing
- confirm whether a suspicious DNS query led to a suspicious web request
- identify downloads, callbacks, or credential submission attempts

## Suricata

Use Suricata to:

- review IDS signatures and categories tied to the same client
- confirm whether the traffic looks like malware delivery, C2, scanning, or exfiltration
- extract related DNS, HTTP, or TLS metadata

## Wazuh

Use Wazuh to:

- correlate the event with host, auth, or network activity
- find repeated events from the same source IP
- pivot on rule ID, agent, or event timeline

## Prometheus and Blackbox

Use Prometheus and Blackbox to:

- confirm sensor services were healthy during the event
- make sure Pi-hole and mitmproxy were reachable while the suspicious traffic occurred
- separate a real quiet period from an observability failure

## Decision points

Treat the activity as likely benign when:

- the client belongs to an approved exercise or testing workflow
- the domains and URLs map to known lab tooling
- the timing matches a planned validation

Treat the activity as likely suspicious when:

- the client reaches unknown or high-risk destinations
- the traffic shows repeated callbacks or staged downloads
- multiple tools agree on the same suspicious pattern
- the client behavior changes suddenly without an expected reason

## Response actions

When the activity is suspicious:

1. block the domain in Pi-hole if appropriate
2. isolate or contain the affected client
3. preserve proxy flows and alert evidence
4. block or watch the destination depending on the exercise scope

When the activity is expected testing:

1. confirm the expected tools detected it
2. record where correlation was strong or weak
3. update rules, dashboards, or playbooks as needed

## Evidence to capture

- client IP
- suspicious domains
- suspicious URLs and request methods
- related Pi-hole entries
- related mitmproxy flows
- related Suricata signatures
- related Wazuh event IDs or alert emails

## Recovery and validation

After containment or exercise completion:

1. confirm the suspicious traffic stops
2. confirm Pi-hole and mitmproxy remain healthy
3. rerun `Invoke-Day1Check.ps1` if the monitoring stack was stressed or restarted
4. tune DNS, IDS, or proxy detections based on the lessons learned

## Related project files

- `targets/sensor_dns_endpoints.yml`
- `targets/sensor_http_endpoints.yml`
- `scripts/python/service_index_assets/service_catalog.json`
- `scripts/python/wazuh_alert_forwarder.py`
- `docs/operator-handbook/tools-user-guide.md`
- `docs/operator-handbook/monitoring-and-threat-identification-guide.md`
