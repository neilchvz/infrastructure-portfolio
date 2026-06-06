# Production Monitoring & Alert Routing

## The Problem

For clients whose business operations depend on reliable internet — live
streaming companies, financial services firms, multi-site organizations
with real-time data dependencies — ISP degradation is not an inconvenience.
It is a business-impacting event.

The challenge at an MSP managing 15–20 monitored client sites was that
internet speed issues were **reactive**. Clients called when their stream
dropped or their VoIP degraded. By the time a ticket existed, the client
was already impacted and frustrated.

Beyond that:

- There was no consistent way to measure office internet performance across
  clients. Home workers, laptops on cellular hotspots, and VPN connections
  all skew results if monitoring is deployed fleet-wide.
- Different clients had wildly different acceptable thresholds — a client
  paying for 1 Gbps with deep packet inspection enabled has a very different
  effective throughput ceiling than one on a clean 500 Mbps line.
- 24x7 clients needed automated on-call paging when alerts fired outside
  business hours. Manual ticket creation defeated the purpose.

The goal was a **proactive, site-aware monitoring system** that could detect
ISP degradation before clients noticed it, route alerts to the right place
automatically, and page the on-call tech for critical clients — with zero
manual handling between alert and ticket.

---

## The Solution

A multi-layer monitoring pipeline built across Addigy MDM and ConnectWise
Manage, using structured alert naming as the routing mechanism.

Each monitored client site has a single **designated stationary office Mac**
scoped to an Addigy Flex Policy by serial number. That machine runs scheduled
internet speed tests via Addigy's built-in Speedtest CLI, storing upload and
download results as Device Facts. Monitoring checks evaluate those facts
against per-client thresholds. When a threshold is breached, Addigy fires an
alert email with a structured subject line that ConnectWise's email parser
uses to automatically create a fully routed, SLA-bound, client-tagged ticket.

For 24x7 clients, that ticket creation triggers on-call paging with no human
in the loop.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Designated Office Mac (stationary, scoped by       │
│  serial number via Addigy Flex Policy)              │
│                                                     │
│  Addigy Speedtest CLI runs on schedule              │
│  ├── internet-speed-download.sh → Device Fact       │
│  └── internet-speed-upload.sh   → Device Fact       │
└────────────────────┬────────────────────────────────┘
                     │  Addigy stores numeric Mbps value
                     ▼
┌─────────────────────────────────────────────────────┐
│  Addigy Monitoring Alert                            │
│  Device Fact < threshold? (per-client, per-site)    │
│  Critical alert: Yes                                │
│  Category: Network                                  │
└────────────────────┬────────────────────────────────┘
                     │  Alert fires → email sent
                     ▼
┌─────────────────────────────────────────────────────┐
│  Structured alert email                             │
│  Subject: [Company: The Class] -                   │
│           Internet Download Speed Low               │
│           (LA_Santa Monica)                         │
│  To: noc@company.com                               │
└────────────────────┬────────────────────────────────┘
                     │  ConnectWise polls mailbox
                     ▼
┌─────────────────────────────────────────────────────┐
│  ConnectWise Email Parser                           │
│  Matches [Company: X] → looks up client record      │
│  Sets: Board=NOC, Type=Alert, Subtype=Network       │
│  Applies: client SLA, priority, company association │
└────────────────────┬────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
┌──────────────────┐   ┌──────────────────────────────┐
│  Standard client │   │  24x7 client                 │
│  Ticket created  │   │  Ticket created               │
│  NOC board       │   │  NOC board                    │
│  Business hours  │   │  On-call tech paged           │
│  SLA applied     │   │  Escalation chain active      │
└──────────────────┘   └──────────────────────────────┘
```

---

## Why a Designated Device

Deploying speedtest scripts fleet-wide produces meaningless data. Laptops
on home Wi-Fi, machines connected over client VPN, devices on cellular
hotspots — all of these return results that reflect the individual user's
connection, not the office ISP.

The solution is one stationary, wired or primary-network Mac per office
location, scoped to the monitoring policy by serial number. This machine
never moves. Its results represent the office connection, not a user.

Addigy Flex Policies make this precise — the policy only auto-assigns
devices that match the serial number filter. New devices enrolled in that
client's Addigy tenant are never accidentally pulled into the monitoring policy.

---

## Threshold Calculation

Alert thresholds are not set at the contracted ISP speed. That approach
generates constant false-positive alerts because real-world throughput
is always lower than contracted speed due to the network stack.

Each threshold is calculated by the senior architect per client, per site,
accounting for:

- ISP contracted speed
- Firewall hardware throughput ceiling
- Security stack overhead (AMP / IDP / IDPS)
- Client VPN overhead if active
- A variance buffer appropriate to the client's business criticality

### Example — The Class (LA Santa Monica)

The Class streams live fitness classes from their Santa Monica studio.
Degradation directly impacts paying subscribers mid-class.

| Layer | Calculation |
|-------|-------------|
| Contracted speed | 500 Mbps |
| Firewall ceiling | No reduction (hardware rated above contracted) |
| AMP + IDP overhead | ~20% → 400 Mbps effective |
| Client VPN | Not active → no reduction |
| Variance buffer | Conservative — livestream dependency |
| **Alert threshold** | **300 Mbps** |

The threshold is intentionally conservative. A brief dip to 320 Mbps
during a live stream is not acceptable for this client even though it
is technically above 60% of contracted speed.

See [`config-reference/threshold-guide.md`](./config-reference/threshold-guide.md)
for the full methodology and additional examples.

---

## Alert Naming as a Routing Mechanism

The alert name in Addigy becomes the email subject line. The subject line
is what ConnectWise's email parser uses to route the ticket.

```
[Company: The Class] - Internet Download Speed Low (LA_Santa Monica)
```

This single string carries:
- The client identity for ConnectWise company association
- The metric and direction for human readability in the ticket queue
- The site identifier for multi-location clients

The parser matches on `[Company: X]`, links to the correct company record,
and applies the board, type, SLA, and escalation rules configured for that
client — automatically.

A correctly named alert requires no manual ticket handling from alert to
resolution. A misconfigured name breaks the entire routing chain silently.

See [`config-reference/alert-naming-convention.md`](./config-reference/alert-naming-convention.md)
for the full naming standard and common failure modes.

---

## Scale

At full deployment this system manages:

- **15–20 monitored client sites**
- **2 alerts per site** (upload + download)
- **Multiple locations per client** where applicable (The Class monitors
  three streaming locations across LA and New York)
- **Varying thresholds** per client and per site based on individual
  network stack analysis

Each new client site requires configuration across Addigy and ConnectWise
but no code changes. The system is designed to extend by convention,
not by modification.

---

## Stack

| Tool | Role |
|------|------|
| **Addigy MDM** | Policy scoping, Device Facts, Monitoring Alerts, alert email delivery |
| **Addigy Speedtest CLI** | WAN speed measurement on managed macOS devices |
| **Bash** | Device Fact scripts — speed test execution and output parsing |
| **ConnectWise Manage** | Email parsing, ticket creation, SLA enforcement, on-call routing |

---

## Repository Structure

```
production-monitoring/
├── README.md                                  ← this file
├── device-facts/
│   ├── internet-speed-download.sh             ← Addigy Device Fact script
│   └── internet-speed-upload.sh              ← Addigy Device Fact script
└── config-reference/
    ├── threshold-guide.md                     ← threshold calculation methodology
    ├── alert-naming-convention.md             ← alert naming standard + CW routing
    └── connectwise-parser-rules.md            ← ConnectWise parser configuration reference
```

---

## Outcome

| Metric | Before | After |
|--------|--------|-------|
| Detection method | Reactive — client calls when impacted | Proactive — alert fires before client notices |
| Ticket creation | Manual — tech receives email and creates ticket | Automatic — parser creates fully routed ticket |
| On-call paging for 24x7 clients | Manual — depended on NOC tech seeing the email | Automatic — triggered by ticket creation |
| Threshold accuracy | N/A — no monitoring existed | Per-client, per-site, stack-aware |
| False positives | N/A | Minimal — thresholds account for full network stack |

---

*Part of the [Automation Portfolio](https://github.com/neilchvz)*
