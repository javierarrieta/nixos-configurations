# AMD GPU Grafana Dashboard for llm01 — Design

## Goal

Provide a Grafana dashboard that visualizes the AMD 8060S (Strix Halo, gfx1151) iGPU
metrics on the `llm01` host, which currently lacks GPU panels in the existing
"Node Exporter Full" dashboard.

## Approach

Build a standalone, importable Grafana dashboard JSON that queries **existing**
node_exporter metrics. No new exporter is required.

### Why no new exporter?

`llm01` already enables the node_exporter `drm` collector
(`prometheus.nodeExporter.collectors = [ "drm" ]`), and the `hwmon` collector is
enabled by default. On AMD GPUs these two collectors export everything needed:

- `node_drm_gpu_busy_percent` — GPU utilization (%)
- `node_drm_memory_vram_used_bytes` / `node_drm_memory_vram_size_bytes` — VRAM
- `node_drm_memory_gtt_used_bytes` / `node_drm_memory_gtt_size_bytes` — GTT (120 GB carve-out)
- `node_hwmon_temp_celsius` — GPU temperature (label "edge")
- `node_hwmon_power_average_watt` — power draw (label "slowPPT")
- `node_hwmon_freq_freq_mhz` — sclk / mclk clocks
- `node_hwmon_chip_names{chip_name="amdgpu"}` — filter to the AMD hwmon chip

node_exporter 1.10.2 (shipped by nixpkgs nixos-25.11) supports both collectors.

The AMD hwmon chip appears under a `chip` label like `0000:0b:00_0_0000:0c:00_0`.
To avoid picking up CPU/NVMe hwmon sensors, hwmon panels join to
`node_hwmon_chip_names{chip_name="amdgpu"}` via `group_left`.

## Deliverable

`hosts/llm01/amdgpu-dashboard.json` — a standalone Grafana dashboard JSON.

Import method: Grafana → Dashboards → Import → Upload JSON. Grafana prompts to
bind the `$datasource` template variable on import.

No Nix configuration changes are required.

## Dashboard Structure

### Template variables

| Variable | Type | Purpose |
|----------|------|---------|
| `datasource` | Prometheus datasource | Bound on import |
| `instance` | query on `node_drm_gpu_busy_percent` | Filter to a node_exporter instance; defaults to llm01 |
| `card` | query on `node_drm_gpu_busy_percent` | GPU card (card0) |
| `chip` | query on `node_hwmon_chip_names{chip_name="amdgpu"}` | amdgpu hwmon chip |

### Row: "AMD GPU (llm01)" — 8 panels

| Panel | Type | Query |
|-------|------|-------|
| GPU Utilization (%) | timeseries | `node_drm_gpu_busy_percent{instance="$instance", card="$card"}` |
| GPU Busy (current) | stat/gauge | Same query, current value |
| VRAM Used (GB) | timeseries | `node_drm_memory_vram_used_bytes{instance="$instance"}` + total as dashed reference line, `/1e9` |
| Temperature (°C) | timeseries | `node_hwmon_temp_celsius` joined to amdgpu chip, with crit threshold line |
| Power Draw (W) | timeseries | `node_hwmon_power_average_watt` on amdgpu chip |
| Core Clock sclk (MHz) | timeseries | `node_hwmon_freq_freq_mhz{sensor="sclk"}` on amdgpu chip |
| Memory Clock mclk (MHz) | timeseries | `node_hwmon_freq_freq_mhz{sensor="mclk"}` on amdgpu chip |
| GTT Memory Used (GB) | timeseries | `node_drm_memory_gtt_used_bytes{instance="$instance"} / 1e9` |

### hwmon query pattern

hwmon panels filter to the AMD GPU chip with a join:

```promql
node_hwmon_temp_celsius{instance="$instance"}
  * on (instance, chip) group_left (chip_name)
  node_hwmon_chip_names{chip_name="amdgpu"}
```

The join matches on `instance` + `chip` only — `node_hwmon_chip_names` has no
`sensor` label — and multiplies every sensor of the amdgpu chip by 1, keeping the
`chip_name` label. This restricts temp/power/clock panels to the amdgpu chip only.

## Acceptance Criteria

1. Dashboard JSON imports cleanly into Grafana (single `$datasource` prompt).
2. Panels populate from existing `node_drm_*` and `node_hwmon_*` metrics when
   `instance` = llm01.
3. hwmon panels show only the AMD GPU chip (no CPU/NVMe sensors).
4. Valid JSON (`jq .` parses without error).
