# Brute-Force Response Playbook

## Purpose

Use this playbook when a client appears to be repeatedly authenticating against a monitored lab service such as the practice auth or API target at `192.168.1.70:8080`.

This playbook assumes the current project layout:

- monitoring host at `192.168.1.3`
- sensor VM at `192.168.1.6`
- practice auth or API target at `192.168.1.70:8080`

## Trigger conditions

Start this playbook when any of these happen:

- Wazuh raises an authentication or repeated-access style alert
- Suricata shows repeated requests to the same auth endpoint
- mitmproxy shows repeated login or token requests from one client
- the practice target becomes slow or unreachable during repeated auth attempts
- Alertmanager sends a threat notification that names the auth target

## Immediate goals

- confirm the target and source are real
- decide whether the activity is expected testing or unauthorized brute force
- contain the attacking client if needed
- preserve enough evidence to improve detections afterward

## First 5 minutes

1. Confirm the alert details in Wazuh or Alertmanager:
   - source IP
   - target endpoint
   - event time
   - agent name
   - rule ID and severity
2. Open the service index and confirm the target still appears reachable.
3. Check Prometheus or Grafana for `practice_auth_api` health around the same time.
4. Decide whether the source IP belongs to an approved tester or a suspicious lab client.

## Triage checklist

- Is the source IP a known test workstation?
- Are the requests concentrated on `/login`, `/auth`, `/token`, or a similar endpoint?
- Are failed responses repeating with the same username, header, or user agent?
- Did service latency or failures increase while the requests were happening?
- Did the same source also trigger Suricata or Wazuh events on other services?

## Investigation pivots

### Wazuh

Use Wazuh to:

- review the original fired rule
- confirm whether the target had related host or auth events
- look for repeated events from the same source IP
- inspect surrounding timeline activity on the same agent

## Suricata

Use Suricata to:

- confirm the repeated flow pattern
- identify related HTTP, TLS, or DNS metadata
- check whether the traffic also looks like scanning or exploit prep

## mitmproxy

Use mitmproxy to:

- inspect repeated `POST` or auth-related requests
- compare headers, body size, path, and timing
- check status codes such as repeated `401`, `403`, or `429`
- identify whether the client is reusing the same credentials or rotating attempts

## Prometheus and Blackbox

Use Prometheus and Blackbox to:

- confirm whether `practice_auth_api` stayed up
- check whether latency spiked during the attack window
- determine whether the auth service degraded under repeated requests

## Decision points

Treat the event as likely benign lab activity when:

- the source IP belongs to an approved tester
- the timing matches a planned exercise
- the request pattern matches expected validation traffic

Treat the event as likely suspicious when:

- the source is unknown or out of scope for the exercise
- the request volume is sustained and repetitive
- the same client is touching multiple auth endpoints
- the requests continue after obvious failures

## Response actions

When the activity is suspicious:

1. isolate or block the attacking client on the lab network
2. snapshot or preserve the target if you want to inspect auth logs later
3. preserve relevant Wazuh, Suricata, and mitmproxy evidence
4. note whether rate limiting, IP blocking, or auth hardening is needed

When the activity is an expected exercise:

1. keep the traffic confined to the practice segment
2. confirm the detections fired as expected
3. record any missed detections or noisy alerts for tuning

## Evidence to capture

- alert email or Wazuh event ID
- source IP and target endpoint
- timeline of repeated attempts
- relevant mitmproxy flow examples
- any Suricata signature IDs or categories
- Prometheus target health or latency during the event

## Recovery and validation

After containment or exercise completion:

1. confirm the target is reachable again
2. rerun `Invoke-Day1Check.ps1` if the stack was affected
3. confirm the practice target still appears in Prometheus and the service index
4. update detections, rate limits, or playbook notes if gaps were discovered

## Related project files

- `targets/practice_http_endpoints.yml`
- `scripts/python/service_index_assets/service_catalog.json`
- `scripts/python/wazuh_alert_forwarder.py`
- `prometheus.yml`
- `alert.rules.yml`
- `docs/operator-handbook/monitoring-and-threat-identification-guide.md`
