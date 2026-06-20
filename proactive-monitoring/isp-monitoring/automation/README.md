# Monitoring & Ticketing Configuration

This is the off-the-shelf half of the project, the part that didn't require writing any code, just wiring two existing tools together correctly. For the piece that had to be built from scratch, see [TypeScript](../typescript/). For the full origin story and how both pieces fit together, see the [project overview](../README.md).

---

## The pieces

**An uptime monitoring tool** runs a ping check against each client's ISP circuit on a fixed interval, independent of any device record. When a circuit goes down, it sends a single alert email. Recovery and summary notification emails are deliberately turned off, since the closer service handles recovery detection on its own by checking the monitoring tool's API directly, an email for it was never actually needed.

**A PSA's email connector** is existing infrastructure, not something built for this project. It watches an inbox and creates tickets from incoming emails based on subject-line parsing rules. Each client, and each ISP circuit if a client has more than one, gets its own parsing rule.

## The naming convention that makes everything else possible

There's no shared database or webhook connecting the monitoring tool to the PSA. The only thing linking a ping check to a ticket is that they both contain the exact same string, set once, in the monitor's name:

[Company: CompanyID | ISP Name]

Example: `[Company: ExampleCorp | Pilot Fiber]`

This string shows up in three places independently: the monitor's name in the monitoring tool, the subject line of the alert email it sends, and the summary of the ticket the PSA creates from that email. Because all three are identical, the closer service can take a monitor's name straight from the monitoring API and use it as a search string against the PSA, no mapping table required.

If a client runs more than one ISP circuit, a primary and a failover for example, each circuit gets its own monitor and its own parsing rule, with the ISP name being the part that distinguishes them. Same client, multiple monitors, multiple tickets, multiple parsing rules, each one independent.

## Parsing rule structure

Each rule needs:

- **Subject line pattern**, matching the monitor's naming convention exactly: `Monitor is DOWN: [Company: {company} | ISP Name]`
- **Parsing variable**, mapping `{company}` to the PSA's company identifier field
- **Text to search for**, the literal company identifier string the rule should match against
- **Routing fields**, board, priority, service type, status, set however fits how these tickets should appear on the board

## Rolling out to a new client

Three steps, no code involved:

1. **Create a monitor** for the client's ISP circuit using the `[Company: CompanyID | ISP Name]` naming convention, pointed at the circuit's public IP.
2. **Add a parsing rule** in the PSA's email connector matching that monitor's naming pattern, with the company variable mapped correctly.
3. **Nothing else.** The closer service polls every monitor on the account automatically and picks up the new one on its next cycle, no code change or redeploy required.

## Why the monitoring tool was changed in the first place

The original setup used a ping monitor tied to a device record inside the RMM platform, and that device was what told the system which client an alert belonged to. The problem was the device had its own lifecycle. When it got retired during routine offboarding, the monitor's routing went with it, and it stopped generating tickets entirely with no warning.

Moving to a dedicated monitoring tool, with routing handled by naming convention instead of hardware association, removed that dependency completely. A monitor now has nothing to do with any device record, so retiring a laptop or a server has zero effect on whether a client's ISP is being watched.
