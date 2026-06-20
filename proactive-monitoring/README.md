# Proactive Monitoring

This category covers monitoring built to catch problems before a client has to report them, and where possible, to close the loop automatically once the problem resolves itself.

The shared idea across everything here is the same regardless of what's being watched: check something on a schedule, compare it against what "normal" looks like, and act when it changes. What varies project to project is what's being monitored, what tool does the watching, and how much of the response is automated versus left for a human to act on.

---

## What lives here

**[ISP Monitoring](isp-monitoring/)** — watches client ISP circuits for outages, creates a ticket automatically when one drops, and closes that ticket automatically once the circuit recovers. Built to replace a fragile setup where monitors were tied to device records and silently broke during routine offboarding.

**[Throughput Monitoring](throughput-monitoring/)** — runs scheduled speed tests against a designated office device per client site, alerts when throughput drops below a per-client calculated threshold, and routes the resulting ticket through ConnectWise with automatic on-call paging for 24x7 clients. Detection and routing only, no automatic resolution, the goal is catching degradation before a client notices, not fixing it.

---

## A note on how these are documented

Where a project involves real code written for an employer, what's documented here is the architecture and the pattern, not the production code itself. Example files use placeholder values in place of real credentials, client identifiers, or proprietary configuration, but follow the same working logic as what's actually deployed. The goal is that the reasoning and the structure are real and reusable, even where the exact production code can't be.
