const summaryGrid = document.getElementById("summary-grid");
const docsGrid = document.getElementById("docs-grid");
const alertsContainer = document.getElementById("alerts-container");
const servicesGrid = document.getElementById("services-grid");
const generatedAt = document.getElementById("generated-at");
const alertCount = document.getElementById("alert-count");

function clearNode(node) {
  while (node.firstChild) {
    node.removeChild(node.firstChild);
  }
}

function renderSummary(summary) {
  clearNode(summaryGrid);
  const template = document.getElementById("summary-card-template");
  const cards = [
    { label: "Services", value: summary.total },
    { label: "Healthy", value: summary.healthy },
    { label: "Critical", value: summary.critical },
  ];

  cards.forEach((card) => {
    const clone = template.content.cloneNode(true);
    clone.querySelector(".summary-label").textContent = card.label;
    clone.querySelector(".summary-value").textContent = card.value;
    summaryGrid.appendChild(clone);
  });
}

function renderDocs(docs) {
  clearNode(docsGrid);
  const template = document.getElementById("doc-card-template");

  docs.forEach((doc) => {
    const clone = template.content.cloneNode(true);
    const anchor = clone.querySelector(".doc-card");
    anchor.href = doc.url;
    clone.querySelector(".doc-name").textContent = doc.name;
    docsGrid.appendChild(clone);
  });
}

function renderAlerts(alerts) {
  clearNode(alertsContainer);
  alertCount.textContent = alerts.length === 0 ? "No firing alerts" : `${alerts.length} firing alert(s)`;

  if (alerts.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No Prometheus alerts are firing right now.";
    alertsContainer.appendChild(empty);
    return;
  }

  const template = document.getElementById("alert-card-template");
  alerts.forEach((alert) => {
    const clone = template.content.cloneNode(true);
    clone.querySelector(".alert-name").textContent = alert.alertname;
    const severity = clone.querySelector(".alert-severity");
    severity.textContent = alert.severity;
    severity.dataset.severity = alert.severity;
    clone.querySelector(".alert-instance").textContent = alert.instance || "n/a";
    clone.querySelector(".alert-job").textContent = [alert.job, alert.service_name].filter(Boolean).join(" / ");
    alertsContainer.appendChild(clone);
  });
}

function renderServices(services) {
  clearNode(servicesGrid);
  const template = document.getElementById("service-card-template");

  services.forEach((service) => {
    const clone = template.content.cloneNode(true);
    clone.querySelector(".service-group").textContent = service.group;
    const status = clone.querySelector(".service-status");
    status.textContent = service.status;
    status.dataset.status = service.status;
    clone.querySelector(".service-name").textContent = service.name;
    const link = clone.querySelector(".service-link");
    link.textContent = service.url;
    const href = service.url.startsWith("ssh ") || !service.url.includes("://") ? "#" : service.url;
    link.href = href;
    if (href === "#") {
      link.removeAttribute("target");
      link.removeAttribute("rel");
    }
    clone.querySelector(".service-notes").textContent = service.notes;
    clone.querySelector(".service-username").textContent = service.username;
    clone.querySelector(".service-password-source").textContent = service.password_source;
    clone.querySelector(".service-detail").textContent = service.detail;
    clone.querySelector(".service-latency").textContent = `${service.latency_ms} ms`;
    servicesGrid.appendChild(clone);
  });
}

async function refreshStatus() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    const payload = await response.json();
    document.getElementById("page-title").textContent = payload.title;
    generatedAt.textContent = `Last updated ${payload.generated_at}`;
    renderSummary(payload.summary);
    renderDocs(payload.docs);
    renderAlerts(payload.alerts);
    renderServices(payload.services);
  } catch (error) {
    generatedAt.textContent = `Status refresh failed: ${error}`;
  }
}

refreshStatus();
window.setInterval(refreshStatus, 30000);
