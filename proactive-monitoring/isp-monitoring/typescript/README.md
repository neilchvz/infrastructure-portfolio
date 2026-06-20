# TypeScript Service

This is the piece that closes the loop. Everything else in this project (the monitoring tool, the PSA's email parser) is off-the-shelf configuration. This is the part that had to be written, because nothing in the existing toolchain could notice an outage had resolved and act on it without a human checking manually.

For the full picture, the original problem this solves and how this service fits with the monitoring and ticketing configuration around it, see the [project overview](../README.md).

---

## What it does

Every five minutes, it asks the monitoring tool's API for the current status of every monitor. For any monitor reporting as up, it searches the PSA for an open ticket whose summary matches that monitor's name. If one exists, it posts an internal note documenting the recovery, then closes the ticket.

It keeps no memory between polls. Every single cycle checks the PSA directly rather than trusting anything tracked locally. That's worth explaining, because it wasn't the first design.

## A design decision worth explaining

The first version tracked state in memory, a set of "which monitors currently have an open ticket," built once on startup by querying the PSA for existing open tickets. That worked until the service redeployed, which wiped the in-memory state and meant any ticket that opened and closed between deploys got missed entirely.

The fix was to stop tracking state locally at all. Every poll asks the PSA fresh: is there an open ticket matching this monitor right now. No memory, no state to lose, no special-casing for what happens after a restart. The PSA is the system of record, not the service. It costs one extra API call per monitor per poll cycle, a trivial trade for a service running every five minutes, in exchange for a service that's correct regardless of how often it restarts.

## Files

src/

├── index_example.ts            # entry point, starts the polling loop on an interval

├── monitor_example.ts           # the poll cycle: check status, find and close matching tickets

├── uptimerobot_example.ts        # API client for the monitoring tool

└── connectwise_example.ts         # API client for the PSA

Each API integration lives in its own file, separate from the orchestration logic in `monitor_example.ts`. That split means swapping either tool later only touches one file.

These are working examples with placeholder values in place of real credentials and identifiers. The logic, request formats, and error handling are real, what's swapped out is anything specific to a real account or client.

## Implementation notes

A few things that weren't obvious going in, and cost real debugging time to figure out:

**Closing a ticket needs JSON Patch format, not a plain object.** A request body like `{"status": {"id": 653}}` gets rejected outright. It has to be an array of patch operations:
```json
[{"op": "replace", "path": "/status", "value": {"id": 653}}]
```

**Status IDs are scoped per board, not global.** There's no single "closed" ID across an entire PSA instance. The same status can have a different ID on every board, and the only reliable way to find it is to query an already-closed ticket on the specific board you're targeting.

**PSA permission scoping has a non-obvious second layer.** Standard ticket edit permissions let the API read and modify most fields without issue, but changing status to closed specifically required a second, separately named permission that wasn't where I expected to find it. Worth checking explicitly rather than assuming standard edit access covers status changes.

**Search syntax doesn't always handle special characters cleanly.** Searching for a summary containing square brackets didn't filter reliably through the API's query syntax. The workaround was to search on a broader, bracket-free substring, then filter the results precisely in code. Broad query, precise filter in the application layer, rather than fighting the query syntax to do all the work.

## Stack

| Layer | Tool | Why |
|---|---|---|
| Language | TypeScript | Type safety on deeply nested API response shapes from two different third-party services |
| Runtime | Node.js | Lightweight, appropriate for a polling service with minimal compute needs |
| HTTP client | Axios | Simple requests, no need for anything heavier |
| Hosting | Railway | Auto-deploys on push, generous free tier for a service this size |

## Environment variables

| Variable | Purpose |
|---|---|
| `UPTIMEROBOT_API_KEY` | Read-only key, scoped to listing monitors only |
| `CW_COMPANY` | PSA company identifier |
| `CW_PUBLIC_KEY` | PSA API member public key |
| `CW_PRIVATE_KEY` | PSA API member private key |
| `CW_CLIENT_ID` | PSA developer portal client ID |
| `CW_BASE_URL` | PSA API base URL |
| `POLL_INTERVAL_MS` | Poll frequency in milliseconds |

## Deployment

Connected to its repository, every push to `main` redeploys automatically.

Build command: npm run build

Start command: npm run start
