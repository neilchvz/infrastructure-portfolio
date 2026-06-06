# Alert Naming Convention

## Overview

Addigy alert names are not just labels — they are the primary data payload
delivered to ConnectWise Manage via email. The alert name becomes the email
subject line, which the ConnectWise email parser reads to automatically
route, tag, and classify the resulting ticket.

A correctly named alert requires zero manual ticket handling. A poorly named
alert lands in a generic queue with no client association and no SLA.

---

## Format

```
[Company: {Client Name}] - {Metric} {Direction} ({Site Identifier})
```

### Fields

| Field | Description | Example |
|-------|-------------|---------|
| `{Client Name}` | Exact client name as it appears in ConnectWise | `The Class` |
| `{Metric}` | What is being measured | `Internet Download Speed`, `Internet Upload Speed` |
| `{Direction}` | Alert condition | `Low` |
| `{Site Identifier}` | Location in format `Region_City` | `LA_Santa Monica`, `NY_New York` |

### Full Examples

```
[Company: The Class] - Internet Download Speed Low (LA_Santa Monica)
[Company: The Class] - Internet Upload Speed Low (LA_Santa Monica)
[Company: The Class] - Internet Download Speed Low (NY_New York)
[Company: Acme Corp] - Internet Download Speed Low (HQ_Chicago)
```

---

## Why the `[Company: X]` Prefix

ConnectWise Manage email parsing rules use subject line pattern matching
to determine how an inbound email should be processed. The `[Company: X]`
format is the trigger pattern the parser looks for.

When a matching email arrives, ConnectWise automatically:

- Associates the ticket with the correct client company record
- Assigns it to the designated board (NOC / Network Alerts)
- Sets the ticket type to Alert
- Applies the client's contracted SLA
- Triggers on-call paging for clients with 24x7 support agreements

None of this requires a technician to touch the ticket. The alert name
does the routing.

---

## Client Name Must Match Exactly

The client name in the alert must match the company name in ConnectWise
character for character. A mismatch causes the parser to fail silently —
the ticket is created but not associated with any client, and no SLA
or on-call routing is applied.

Before creating a new alert, confirm the exact company name in ConnectWise:

```
ConnectWise → Companies → search client → copy Display Name exactly
```

Common failure modes:
- `The Class` vs `The Class LLC` — parser fails
- `Acme` vs `Acme Corp` — parser fails
- Extra spaces, different capitalisation — parser fails

---

## Site Identifier Format

The site identifier uses `Region_City` format. This makes alerts human-readable
in both Addigy and ConnectWise without requiring a lookup table.

| Site | Identifier |
|------|-----------|
| Los Angeles — Santa Monica office | `LA_Santa Monica` |
| New York — main office | `NY_New York` |
| Chicago — HQ | `HQ_Chicago` |
| San Francisco — remote office | `SF_Remote` |

Use consistent identifiers across upload and download alerts for the same site.
Inconsistent naming makes historical ticket analysis harder.

---

## One Alert Per Metric Per Site

Each monitored site requires two alerts:

| Alert | Device Fact | Condition |
|-------|-------------|-----------|
| Download | `{Client} - InternetDownloadSpeed` | `< {threshold}` |
| Upload | `{Client} - InternetUploadSpeed` | `< {threshold}` |

Upload and download thresholds may differ. A client with asymmetric internet
(e.g. 1 Gbps down / 500 Mbps up) should have separate thresholds reflecting
each direction. See `threshold-guide.md` for the full calculation methodology.

---

*Part of the [Automation Portfolio](https://github.com/neilchvz) · Neil Chavez · Creator of things.*
