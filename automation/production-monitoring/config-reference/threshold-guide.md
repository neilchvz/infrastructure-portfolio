# Threshold Calculation Guide

## Overview

Setting the right alert threshold is not as simple as using the contracted ISP speed.
A threshold set too high generates constant false-positive alerts. A threshold set too
low misses real degradation events until the client is already impacted.

The correct threshold accounts for every layer of the network stack that consumes
bandwidth before it reaches the end user. This guide documents the calculation
methodology used across all monitored sites.

This decision is made by the senior network architect per client and per site —
not by the technician configuring the alert.

---

## The Calculation

```
Contracted Speed
    − Firewall hardware ceiling
    − Security stack overhead (AMP / IDP / IDPS)
    − Client VPN overhead (if active)
    − Natural variance buffer
= Recommended Alert Threshold
```

Work through each layer in order. Each reduction is applied to the running total,
not the original contracted speed.

---

## Layer Breakdown

### 1. Contracted ISP Speed
The speed the client is paying for. This is the ceiling — actual throughput
will always be below this due to the layers below.

Get this from the client's ISP contract or last invoice.

---

### 2. Firewall Hardware Ceiling
Every firewall has a maximum throughput rating independent of the ISP speed.
A client paying for 1 Gbps on a firewall rated for 750 Mbps will never see
more than 750 Mbps regardless of ISP performance.

Check the firewall model's datasheet for:
- **Stateful throughput** — baseline max without any security features enabled
- **Threat protection throughput** — max with security features active (use this one)

| Reduction | Typical Range |
|-----------|--------------|
| Firewall ceiling below contracted speed | 10–40% reduction |

---

### 3. AMP / IDP / IDPS Overhead
Advanced Malware Protection (AMP), Intrusion Detection (IDP), and Intrusion
Prevention (IDPS) perform deep packet inspection on all traffic. This is
CPU-intensive and reduces effective throughput.

The overhead varies by vendor and feature set, but a consistent working range:

| Security Feature | Typical Throughput Impact |
|-----------------|--------------------------|
| IDP only | ~10–15% reduction |
| IDP + AMP | ~15–25% reduction |
| IDP + AMP + SSL inspection | ~25–40% reduction |

Apply this reduction to the firewall ceiling from Step 2, not the contracted speed.

---

### 4. Client VPN Overhead
If users connect to a client VPN concentrator hosted behind this firewall, VPN
tunneling adds encryption overhead that further reduces available bandwidth —
even for users who are not actively on VPN, as the VPN service itself consumes
firewall resources.

| VPN Status | Typical Throughput Impact |
|------------|--------------------------|
| No VPN | 0% |
| VPN available, low usage | ~5–10% reduction |
| VPN available, high concurrent usage | ~10–20% reduction |

---

### 5. Natural Variance Buffer
Speedtest results are not perfectly consistent. ISP throughput fluctuates
slightly throughout the day. A buffer prevents alert fatigue from minor
variance that does not represent a real degradation event.

Recommended buffer: **10–15% below your calculated threshold.**

This means the alert only fires when throughput is meaningfully below
acceptable levels — not on a single test result that caught a 30-second
ISP hiccup.

---

## Worked Examples

### Example A — The Class (LA Santa Monica Office)
| Layer | Value | Notes |
|-------|-------|-------|
| Contracted speed | 500 Mbps | ISP contract |
| Firewall ceiling | 500 Mbps | Firewall rated above contracted speed — no reduction |
| AMP + IDP overhead | ~20% reduction | → 400 Mbps |
| Client VPN | None active | → 400 Mbps |
| Variance buffer | ~25% | Business criticality: livestreaming |
| **Alert threshold set at** | **300 Mbps** | Conservative due to livestream dependency |

The Class streams live fitness classes from this office. Degradation directly
impacts paying subscribers. The threshold is intentionally conservative.

---

### Example B — Standard Office Client, 1 Gbps, Security Stack
| Layer | Value | Notes |
|-------|-------|-------|
| Contracted speed | 1000 Mbps | ISP contract |
| Firewall ceiling | 750 Mbps | Hardware rated at 750 Mbps threat protection throughput |
| AMP + IDP overhead | ~20% reduction | → 600 Mbps |
| Client VPN | Low usage | ~10% reduction → 540 Mbps |
| Variance buffer | ~10% | Standard office, not business-critical |
| **Alert threshold set at** | **500 Mbps** | |

---

### Example C — Small Client, 500 Mbps, No Security Stack
| Layer | Value | Notes |
|-------|-------|-------|
| Contracted speed | 500 Mbps | ISP contract |
| Firewall ceiling | 500 Mbps | No reduction |
| Security stack | None | No reduction |
| Client VPN | None | No reduction |
| Variance buffer | ~15% | |
| **Alert threshold set at** | **425 Mbps** | |

---

## Key Principle

The threshold represents the minimum acceptable throughput given the client's
full network stack — not a percentage of contracted speed applied uniformly
across all clients.

Two clients with the same ISP package will have different thresholds if their
security posture, firewall hardware, or business criticality differs.

Always confirm the threshold with the senior architect before deploying a
new monitoring alert.

---

*Part of the [Automation Portfolio](https://github.com/neilchvz) · Neil Chavez · Creator of things.*
