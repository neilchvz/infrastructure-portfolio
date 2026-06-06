# ConnectWise Manage — Email Parser Configuration

## Overview

ConnectWise Manage's email parser is what transforms a raw Addigy alert
email into a properly routed, SLA-bound, client-tagged support ticket —
automatically, with no technician involvement.

This document describes how the parser rules are structured to support
the production monitoring workflow. It is intended as a reference for
replicating or extending the system, not as a step-by-step UI walkthrough.

---

## How It Works

Addigy sends an alert email to the helpdesk inbox when a monitored
Device Fact breaches its threshold. That inbox is configured as a
ConnectWise mailbox. ConnectWise polls the inbox, reads each inbound
email, and applies parser rules to determine how to create the ticket.

```
Addigy alert fires
      ↓
Email sent to helpdesk inbox (e.g. noc@company.com)
      ↓
ConnectWise polls mailbox
      ↓
Parser evaluates subject line against rules
      ↓
Matching rule fires → ticket created with correct fields
      ↓
24x7 clients → on-call tech paged automatically
```

---

## Parser Rule Structure

ConnectWise email parser rules match on subject line patterns and map
them to specific ticket field values. Each rule defines:

| Field | Description |
|-------|-------------|
| **Match pattern** | Text to find in the subject line |
| **Company** | Client record to associate the ticket with |
| **Board** | Service board to route the ticket to |
| **Type** | Ticket type (Alert, Request, Incident, etc.) |
| **Subtype** | Further classification (Network, Security, etc.) |
| **Priority** | Ticket priority level |
| **SLA** | SLA to apply (drives response time targets) |

---

## Pattern Matching

The parser uses the `[Company: X]` prefix in the alert subject line
as its primary match key.

### Example Rule

| Setting | Value |
|---------|-------|
| Subject contains | `[Company: The Class]` |
| Company | The Class *(linked to CW company record)* |
| Board | NOC |
| Type | Alert |
| Subtype | Network |
| Priority | High |
| SLA | 24x7 Response SLA |

When an email arrives with `[Company: The Class]` in the subject, this
rule fires and the ticket is created with all fields pre-populated.

---

## Board Configuration

All internet speed alerts route to the **NOC board**. This board is
configured separately from the standard helpdesk board with:

- Dedicated ticket statuses (New Alert → Acknowledged → Investigating → Resolved)
- Alert-specific SLA targets
- On-call escalation rules for 24x7 clients
- Separate reporting from day-to-day helpdesk volume

Routing alerts to the NOC board keeps them visible as infrastructure
events rather than buried in general helpdesk queues.

---

## 24x7 On-Call Routing

Clients with 24x7 support agreements have an additional escalation rule
configured in ConnectWise. When a ticket is created on the NOC board
outside business hours and the client is flagged as 24x7:

1. Ticket is created and assigned to the on-call rotation
2. On-call tech is paged via the configured escalation path
3. Tech acknowledges within SLA window or escalation continues

This is entirely driven by the ticket being correctly tagged to the right
client — which flows from the alert name being correctly structured.
A misconfigured alert name breaks the entire escalation chain.

---

## Extending to New Clients

When onboarding a new monitored site, the following must be configured
in order:

1. **Confirm company name** in ConnectWise — exact match required
2. **Create Device Facts** in Addigy — one for upload, one for download
3. **Create Flex Policy** scoped to the designated office device by serial number
4. **Create Monitoring Alerts** in Addigy — one per metric, using the correct naming convention (see `alert-naming-convention.md`)
5. **Confirm parser rule exists** in ConnectWise for the new client — or create one
6. **Set thresholds** based on full stack analysis (see `threshold-guide.md`)
7. **Verify end-to-end** — trigger a test alert and confirm the ticket is created with the correct client, board, type, and SLA

Do not skip step 7. A misconfigured parser rule that fails silently means
real alerts are lost without any indication of failure.

---

## Common Failure Modes

| Symptom | Likely Cause |
|---------|-------------|
| Ticket created, no client association | `[Company: X]` name doesn't match CW exactly |
| Ticket on wrong board | Parser rule missing or misconfigured |
| No SLA applied | Company record not linked in parser rule |
| On-call not paged | Client not flagged 24x7, or board escalation rule missing |
| No ticket created at all | Mailbox polling issue, or email landed in spam |

---

*Part of the [Automation Portfolio](https://github.com/neilchvz) · Neil Chavez · Creator of things.*
