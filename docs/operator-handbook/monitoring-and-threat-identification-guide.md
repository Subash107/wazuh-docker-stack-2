# Monitoring And Threat Identification Guide

## Main telemetry sources

### Wazuh

Use Wazuh as the main alert correlation plane.

Look for:

- Suricata IDS alerts
- system log anomalies
- authentication failures
- suspicious process or file activity
- repeated events from the same IP, host, or user

### Suricata

Use Suricata for:

- IDS signatures
- suspicious network categories
- HTTP, DNS, TLS, and flow metadata

Important files:

- `/var/log/suricata/eve.json`

### Pi-hole

Use Pi-hole for:

- DNS query patterns
- blocked domains
- unusual client request volume
- malware, adware, or tracking related destinations

Important view:

- query log in the Pi-hole admin dashboard

### mitmproxy

Use mitmproxy for:

- reviewing HTTP and HTTPS flows
- tracing suspicious outbound requests
- checking headers, hostnames, URIs, and timing

Important view:

- flow list and individual request/response details in the mitmproxy web UI

## Threat identification workflow

1. Check Wazuh first for any fired rules, severity, and affected agent.
2. If the event is network-related, pivot to Suricata details.
3. If the event includes DNS behavior, cross-check the domain in Pi-hole.
4. If the event includes web traffic, review matching flows in mitmproxy.
5. Use Prometheus and Blackbox to confirm whether the sensor services were healthy while the event happened.

## Suspicious patterns to watch

### DNS indicators

- repeated failed lookups to rare domains
- sudden spikes in DNS requests from one client
- suspicious TLDs or random-looking hostnames
- known malware or phishing destinations

### Proxy indicators

- outbound connections to unknown infrastructure
- unexpected authentication headers
- downloads from untrusted hosts
- repeated access to command-and-control style endpoints

### IDS indicators

- high-severity Suricata alerts
- repeated signature hits from the same source
- anomalous protocol use
- scans, brute force attempts, or exploit traffic

## Practical investigation path

### If Wazuh sends a threat alert

Check:

- alert rule ID
- alert groups
- source IP
- destination IP
- agent name
- event time

Then pivot to:

- Wazuh Dashboard for full event context
- Suricata logs for packet and signature context
- Pi-hole for DNS history
- mitmproxy for related HTTP or HTTPS flows

### If a service-health alert fires

Check:

- Prometheus target state
- Blackbox probe result
- current container or systemd status
- firewall changes
- recent config changes

## Service health probes now in place

- ICMP checks for the monitoring host and sensor VM
- HTTP checks for Pi-hole admin and mitmproxy UI
- optional HTTP checks for isolated practice targets
- TCP check for the mitmproxy proxy listener
- DNS probe for Pi-hole on UDP 53

## Documentation to keep open during investigations

- installation guide
- troubleshooting guide
- tools user guide
- access and credentials guide
