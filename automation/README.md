# Automation

Workflow design and system automation across platforms — built from real production problems at an MSP managing multi-client environments.

Each workflow in this repository documents a complete end-to-end solution: the problem it solved, the architecture behind it, and the outcome. Where off-the-shelf tools were the right call, they were used. Where custom scripting was needed, it was written. The goal in both cases was the same — remove the manual human element and make the system self-sustaining.

## Workflows

| Workflow | Description |
|----------|-------------|
| [M365 Offboarding Automation](./offboarding/) | Interactive PowerShell script guiding L1 technicians through a complete M365 offboard — hybrid and cloud-only environments, full audit output, license removal sequenced last by design. |
| [Production Monitoring & Alert Routing](./production-monitoring/) | Site-aware ISP monitoring pipeline across 15–20 client sites — structured alert naming drives automatic ticket creation, SLA assignment, and 24x7 on-call paging in ConnectWise. |
| [FileVault Compliance Automation](./filevault-remediation/) | Continuous macOS compliance automation using Addigy Flex Policies — detects and remediates both disabled FileVault and missing key escrow across managed fleets with zero technician involvement. |

---

Neil Chavez · Creator of things.
<!-- >_ curious aren't we? respect. -->