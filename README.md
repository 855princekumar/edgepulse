# **EdgePulse** 
## **Hybrid Memory & Diagnostics Toolkit for Edge AI/ML, IoT, Robotics, and Drones**

**Version:** 1.0     
**Category:** Edge Computing · Raspberry Pi · AI/ML · Robotics · IoT · Drones    

---

## Overview

EdgePulse is a production-ready hybrid memory optimization and diagnostics framework designed for Raspberry Pi and similar single-board computers used in demanding edge workloads. I engineered this toolkit after repeatedly facing memory saturation, CPU throttling, thermal-induced performance drops, and insufficient system visibility during real deployments across AI/ML inference pipelines, IoT sensor gateways, robotics control systems, and drone telemetry/video nodes.

EdgePulse stabilizes these systems using a combination of:

* Compressed ZRAM swap
* Disk-based fallback swap
* Targeted sysctl tuning
* A lightweight on-demand diagnostics API
* An automated performance validation suite
* A complete rollback mechanism

This ensures predictable behavior under computation-heavy, thermally-constrained, and memory-burst workloads.

---

## Why I Built EdgePulse

Across multiple edge deployments I worked on, the following issues were frequent:

* AI/ML models triggered memory spikes that caused OOM kills
* Thermal throttling degraded inference speed and robotic control frequency
* IoT nodes running multi-protocol workloads became unstable under burst traffic
* Drone compute nodes stalled mid-flight due to insufficient memory headroom
* No unified tool existed to stabilize memory + expose health metrics + validate performance + remain fully reversible

EdgePulse was developed to solve all of these issues in a clean, reproducible, and safe manner.

---

## Real Deployment Scenarios

### AI/ML Inference on SBCs

During deployments involving camera-based YOLO and TFLite models, memory spikes during model initialization and frame buffering caused dropped frames and occasional crashes. After enabling EdgePulse, ZRAM absorbed burst allocations and fallback swap prevented OOM events, resulting in stable FPS and consistent inference loops across Pi 3B+, Pi 4, and Pi 5.

### IoT Gateways and Sensor Nodes

In IoT deployments combining video telemetry, MQTT, multi-sensor aggregation, and buffering, Raspberry Pi nodes exhibited jitter, delayed publishes, and process restarts. EdgePulse improved uptime and delivered a diagnostics API that was used directly by the central monitoring system.

### Robotics Platforms

Robotic systems running sensor fusion, control loops, and mapping experienced reduced loop frequencies and unpredictable latency under moderate load. EdgePulse stabilized memory pressure and improved loop consistency.

### Drone Payload Compute

Pi-based drone payloads performing video encoding, obstacle detection, and live telemetry experienced mid-flight stall events due to memory spikes and thermal throttling. After applying EdgePulse, compute stalls were eliminated and the diagnostics API was integrated with the ground station for predictive monitoring.

---

## Architecture

EdgePulse uses the following components:

* **ZRAM compressed memory** for extremely fast swap in RAM
* **Disk swap fallback** with lower priority for safety
* **Kernel and memory tuning** (swappiness, cache_pressure)
* **Diagnostics API** serving temperature, throttling, swap usage, CPU details, and live benchmarks
* **Validation suite** to automatically test thermal, CPU, memory, and swap behavior
* **Rollback system** to safely revert all changes

All configuration modifications are backed up with versioned suffixes.

---

# **Performance Results (Included in results/)**

All performance comparison graphs are available in the **results/** folder.
The tables below summarize real-world measured improvements before and after applying EdgePulse on Raspberry Pi 3B+, Pi 4, and Pi 5.

---

## **AI/ML Inference Performance (Frames Per Second)**

| Device               | Before FPS | After FPS | Improvement |
| -------------------- | ---------- | --------- | ----------- |
| **Raspberry Pi 3B+** | 2          | 4         | +100%       |
| **Raspberry Pi 4**   | 8          | 12        | +50%        |
| **Raspberry Pi 5**   | 18         | 25        | +38%        |

<img width="2000" height="1200" alt="perf_ai_ml" src="https://github.com/user-attachments/assets/1e5e4bd3-2f28-478f-8b0b-bdf3e9d32470" />

---

## **IoT Gateway Stability (Node Uptime Under Heavy Load)**

| Device               | Before Uptime | After Uptime | Improvement |
| -------------------- | ------------- | ------------ | ----------- |
| **Raspberry Pi 3B+** | 82%           | 99.3%        | +17.3%      |
| **Raspberry Pi 4**   | 88%           | 99.7%        | +11.7%      |
| **Raspberry Pi 5**   | 92%           | 99.9%        | +7.9%       |

<img width="2000" height="1200" alt="perf_iot" src="https://github.com/user-attachments/assets/54441c18-adda-4508-bdb3-3f0a0fdae6d8" />

---

## **Robotics Loop Frequency (Control Loop Hz)**

| Device               | Before Loop Rate | After Loop Rate | Improvement |
| -------------------- | ---------------- | --------------- | ----------- |
| **Raspberry Pi 3B+** | 15 Hz            | 30 Hz           | +100%       |
| **Raspberry Pi 4**   | 25 Hz            | 45 Hz           | +80%        |
| **Raspberry Pi 5**   | 40 Hz            | 60 Hz           | +50%        |

<img width="2000" height="1200" alt="perf_robotics" src="https://github.com/user-attachments/assets/3e49b742-8a2d-4721-8975-987be8c8273f" />

---

## **Drone Compute Stability (Stalls per 10 Flights)**

| Device               | Before Stalls | After Stalls | Improvement  |
| -------------------- | ------------- | ------------ | ------------ |
| **Raspberry Pi 3B+** | 3             | 0            | Eliminated   |
| **Raspberry Pi 4**   | 1             | 0            | Eliminated   |
| **Raspberry Pi 5**   | 0             | 0            | Fully stable |

<img width="2000" height="1200" alt="perf_drone" src="https://github.com/user-attachments/assets/5a51c67f-833f-4965-9676-041d895ba76f" />

---

## Installation

Run:

```
sudo bash install_pi_perf_hybrid.sh
```

This installer performs:

* Installation of zram-tools, sysbench, python dependencies
* Configuration of ZRAM with dynamic sizing based on RAM
* Creation of disk swap fallback at lower priority
* Sysctl tuning for memory
* Deployment of `/opt/pi_perf_api` microservice
* Creation of backups for configuration files
* Systemd unit installation

---

## Performance Validation

Run:

```
sudo bash pi_perf_validate.sh
```

This script performs:

* CPU single-core and multi-core benchmarks
* Memory pressure testing
* Swap hierarchy validation
* Thermal and throttling checks
* API responsiveness test

Outputs:

* `/var/tmp/pi_perf_validation_report.json`
* `/var/tmp/pi_perf_validation_human.txt`

---

## Rollback and Restoration

Rollback restores the system to its exact pre-installation state:

```
sudo bash rollback_pi_perf_hybrid.sh
```

Rollback removes:

* ZRAM configuration
* Fallback swapfile (verified by UUID)
* `/opt/pi_perf_api`
* Systemd units created by EdgePulse
* Restores original system files from backups

---

# Diagnostics API

A key part of EdgePulse is its **on-demand, low-overhead API** running at:

```
http://<pi-ip>:8080/perf
```

### Key Characteristics

* Lightweight Flask microservice
* Activated by systemd
* Sleeps idle with near-zero CPU usage
* When called, runs performance check if report is older than TTL (default: 300s)
* Enforced global rate limit of **1 request every 5 seconds**
* Returns a fully structured JSON report

---

## Example API Output

Below is a real output sample for user convenience:

```
{
  "timestamp": "2025-11-23T11:44:26Z",
  "host": "nodeL7",
  "kernel": "Linux 6.12.25+rpt-rpi-v8 aarch64 unknown",
  "model": "Raspberry Pi 3 Model B Plus Rev 1.3",
  "total_ram_mb": 906,
  "cpu_freqs": "1400000\n1400000\n1400000\n1400000",
  "zram_raw": "NAME       ALGORITHM DISKSIZE   DATA COMPR TOTAL STREAMS MOUNTPOINT
/dev/zram0 lz4           544M 176.5M 56.5M 59.3M       4 [SWAP]",
  "swap_raw": "NAME       TYPE       SIZE   USED PRIO
/swapfile  file      1024M     0B   50
/dev/zram0 partition  544M 183.3M  100",
  "free_raw": "               total        used        free      shared  buff/cache   available
Mem:           906Mi       407Mi       348Mi       9.0Mi       221Mi       499Mi
Swap:          1.5Gi       183Mi       1.4Gi",
  "temperature": "temp=44.0'C",
  "throttled": "throttled=0x50000",
  "sysbench": "sysbench 1.0.20 (using system LuaJIT 2.1.0-beta3)
Running test...
events per second: 267.09 ..."
}
```

---

## Calling the API

From Pi:

```
curl http://localhost:8080/perf
```

From another system:

```
curl http://<pi-ip>:8080/perf
```

Rate limiting response example:

```
{
  "error": "rate_limited",
  "retry_after_seconds": 3.8
}
```

---

## Support and Contribution

Contributions are welcome.
Open issues for:

* Bugs
* Feature requests
* Optimization ideas
* Dashboard integrations (Grafana, Prometheus)

EdgePulse is designed for modular extensions and community-based evolution.

---

## License

Released under the MIT License.
Refer to `LICENSE` for details.

---





