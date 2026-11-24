# CPUPulse

A tiny native macOS menu-bar monitor that draws live CPU and memory sparklines
right in the menu bar. No Electron, no web server — plain Swift/AppKit, idling at
a few MB of RAM and negligible CPU.

![menu bar graph: white CPU line, colored memory line](docs/screenshot.png)

## What it shows

- **White line** — CPU utilization, normalized 0–100% across all cores
  (100% = every core maxed; it cannot exceed 100%).
- **Colored line** — memory used%, where the **color is memory *pressure***, not
  the used% itself:
  - 🟢 green — normal
  - 🟡 yellow — warning
  - 🔴 red — critical

  Height tracks how full RAM looks; color tracks whether the OS is actually
  struggling (swapping / heavy compression). On macOS, used% is normally high and
  healthy, so pressure is the signal that matters.
- Faint white gridlines at 0% and 100%.

Hover for exact values; **left-click opens Activity Monitor**; **right-click** shows
peak/avg stats and a Quit item.

## Build

```sh
./build.sh          # compiles with swiftc -O and packages CPUPulse.app
open CPUPulse.app
```

## Autostart at login

A LaunchAgent (`~/Library/LaunchAgents/com.slvtrs.cpupulse.plist`) runs it at login
with `RunAtLoad` + `KeepAlive`. After editing the source:

```sh
./build.sh
launchctl kickstart -k gui/$(id -u)/com.slvtrs.cpupulse
```

## How it samples

- **CPU:** `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, aggregated across all
  cores, diffed between 2-second samples.
- **Memory used:** `host_statistics64` (active + wired + compressed) ÷ installed RAM.
- **Memory pressure:** `kern.memorystatus_vm_pressure_level` (1 normal / 2 warning /
  4 critical) — the same signal behind Activity Monitor's green/yellow/red.

## Requirements

macOS 12+ · Xcode command-line Swift toolchain.
