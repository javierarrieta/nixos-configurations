# AMD GPU Grafana Dashboard for llm01 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an importable Grafana dashboard JSON that visualizes llm01's AMD 8060S iGPU metrics from existing node_exporter `drm`/`hwmon` collectors.

**Architecture:** A single standalone Grafana dashboard JSON (`hosts/llm01/amdgpu-dashboard.json`) with one row of 8 panels. It queries `node_drm_*` (GPU busy, VRAM, GTT) and `node_hwmon_*` (temp, power, clocks) metrics already exported by node_exporter on llm01. hwmon panels filter to the AMD chip via a `group_left` join on `node_hwmon_chip_names{chip_name="amdgpu"}`.

**Tech Stack:** Grafana dashboard JSON schema (schemaVersion 39), PromQL, `__inputs` datasource binding (DS_PROMETHEUS), template variables (instance/card/chip).

## Global Constraints

- Dashboard JSON must parse with `jq` (acceptance criterion #4).
- All panel queries reference only existing metrics: `node_drm_*` and `node_hwmon_*` (no new exporter — spec "Why no new exporter?").
- hwmon panels must be restricted to the AMD chip via the join documented in the spec (join on `(instance, chip)` only, since `node_hwmon_chip_names` has no `sensor` label).
- Single datasource prompt on import via `__inputs` → `DS_PROMETHEUS`.
- Exactly 8 data panels + 1 row panel + 4 template variables (`DS_PROMETHEUS`, `instance`, `card`, `chip`).
- Saved to `hosts/llm01/amdgpu-dashboard.json`. No Nix changes.

---

### Task 1: Create the AMD GPU dashboard JSON

**Files:**
- Create: `hosts/llm01/amdgpu-dashboard.json`

**Interfaces:**
- Consumes: none (standalone file).
- Produces: `hosts/llm01/amdgpu-dashboard.json` — a complete Grafana dashboard importable via Dashboards → Import → Upload. Later tasks (if any) and the user rely on this exact file path and its 8 panel titles / 4 variable names.

- [x] **Step 1: Create `hosts/llm01/amdgpu-dashboard.json` with the full dashboard content**

Write the following file exactly:

```json
{
  "__inputs": [
    {
      "name": "DS_PROMETHEUS",
      "label": "Prometheus",
      "description": "",
      "type": "datasource",
      "pluginId": "prometheus",
      "pluginName": "Prometheus"
    }
  ],
  "annotations": {
    "list": []
  },
  "editable": true,
  "graphTooltip": 1,
  "links": [],
  "panels": [
    {
      "collapsed": false,
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
      "id": 0,
      "title": "AMD GPU (llm01)",
      "type": "row"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 1 },
      "id": 1,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_drm_gpu_busy_percent{instance=~\"$instance\", card=~\"$card\"}",
          "legendFormat": "{{instance}} {{card}}",
          "refId": "A"
        }
      ],
      "title": "GPU Utilization",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "decbytes",
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "VRAM total" },
            "properties": [
              { "id": "custom.lineStyle", "value": { "dash": [ 10, 10 ] } },
              { "id": "custom.lineWidth", "value": 1 },
              { "id": "custom.fillOpacity", "value": 0 }
            ]
          }
        ]
      },
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 1 },
      "id": 2,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_drm_memory_vram_used_bytes{instance=~\"$instance\", card=~\"$card\"}",
          "legendFormat": "{{instance}} used",
          "refId": "A"
        },
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_drm_memory_vram_size_bytes{instance=~\"$instance\", card=~\"$card\"}",
          "legendFormat": "VRAM total",
          "refId": "B"
        }
      ],
      "title": "VRAM Used",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 1 },
      "id": 3,
      "options": {
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": { "calcs": [ "lastNotNull" ], "fields": "", "values": false },
        "textMode": "auto"
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_drm_gpu_busy_percent{instance=~\"$instance\", card=~\"$card\"}",
          "legendFormat": "GPU Busy",
          "refId": "A"
        }
      ],
      "title": "GPU Busy (current)",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "celsius",
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "crit" },
            "properties": [
              { "id": "custom.lineStyle", "value": { "dash": [ 10, 10 ] } },
              { "id": "custom.lineWidth", "value": 1 },
              { "id": "custom.fillOpacity", "value": 0 }
            ]
          }
        ]
      },
      "gridPos": { "h": 8, "w": 6, "x": 0, "y": 9 },
      "id": 4,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_hwmon_temp_celsius{instance=~\"$instance\", chip=~\"$chip\"} * on (instance, chip) group_left (chip_name) node_hwmon_chip_names{chip_name=\"amdgpu\"}",
          "legendFormat": "{{instance}} {{sensor}}",
          "refId": "A"
        },
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_hwmon_temp_crit_celsius{instance=~\"$instance\", chip=~\"$chip\"} * on (instance, chip) group_left (chip_name) node_hwmon_chip_names{chip_name=\"amdgpu\"}",
          "legendFormat": "crit",
          "refId": "B"
        }
      ],
      "title": "Temperature",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "watt",
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 6, "x": 6, "y": 9 },
      "id": 5,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_hwmon_power_average_watt{instance=~\"$instance\", chip=~\"$chip\"} * on (instance, chip) group_left (chip_name) node_hwmon_chip_names{chip_name=\"amdgpu\"}",
          "legendFormat": "{{instance}}",
          "refId": "A"
        }
      ],
      "title": "Power Draw",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "mhertz",
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 6, "x": 12, "y": 9 },
      "id": 6,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_hwmon_freq_freq_mhz{instance=~\"$instance\", chip=~\"$chip\", sensor=\"sclk\"} * on (instance, chip) group_left (chip_name) node_hwmon_chip_names{chip_name=\"amdgpu\"}",
          "legendFormat": "{{instance}} sclk",
          "refId": "A"
        }
      ],
      "title": "Core Clock (sclk)",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "mhertz",
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": []
      },
      "gridPos": { "h": 8, "w": 6, "x": 18, "y": 9 },
      "id": 7,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_hwmon_freq_freq_mhz{instance=~\"$instance\", chip=~\"$chip\", sensor=\"mclk\"} * on (instance, chip) group_left (chip_name) node_hwmon_chip_names{chip_name=\"amdgpu\"}",
          "legendFormat": "{{instance}} mclk",
          "refId": "A"
        }
      ],
      "title": "Memory Clock (mclk)",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "fieldConfig": {
        "defaults": {
          "unit": "decbytes",
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "showPoints": "never"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [ { "color": "green", "value": null } ]
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "GTT total" },
            "properties": [
              { "id": "custom.lineStyle", "value": { "dash": [ 10, 10 ] } },
              { "id": "custom.lineWidth", "value": 1 },
              { "id": "custom.fillOpacity", "value": 0 }
            ]
          }
        ]
      },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 17 },
      "id": 8,
      "options": {
        "legend": { "calcs": [ "mean", "last", "max" ], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_drm_memory_gtt_used_bytes{instance=~\"$instance\", card=~\"$card\"}",
          "legendFormat": "{{instance}} used",
          "refId": "A"
        },
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "node_drm_memory_gtt_size_bytes{instance=~\"$instance\", card=~\"$card\"}",
          "legendFormat": "GTT total",
          "refId": "B"
        }
      ],
      "title": "GTT Memory Used",
      "type": "timeseries"
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": [ "gpu", "amd", "llm01" ],
  "templating": {
    "list": [
      {
        "name": "DS_PROMETHEUS",
        "type": "datasource",
        "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
        "current": {},
        "hide": 0,
        "includeAll": false,
        "multi": false,
        "query": "prometheus",
        "label": "Data source"
      },
      {
        "name": "instance",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
        "query": { "query": "label_values(node_drm_gpu_busy_percent, instance)", "refId": "A" },
        "current": {},
        "hide": 0,
        "includeAll": true,
        "multi": true,
        "allValue": ".*",
        "refresh": 2,
        "label": "Instance"
      },
      {
        "name": "card",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
        "query": { "query": "label_values(node_drm_gpu_busy_percent{instance=~\"$instance\"}, card)", "refId": "A" },
        "current": {},
        "hide": 0,
        "includeAll": true,
        "multi": true,
        "allValue": ".*",
        "refresh": 2,
        "label": "Card"
      },
      {
        "name": "chip",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
        "query": { "query": "label_values(node_hwmon_chip_names{chip_name=\"amdgpu\", instance=~\"$instance\"}, chip)", "refId": "A" },
        "current": {},
        "hide": 0,
        "includeAll": true,
        "multi": true,
        "allValue": ".*",
        "refresh": 2,
        "label": "Chip"
      }
    ]
  },
  "time": { "from": "now-6h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "AMD GPU (llm01)",
  "uid": "amdgpu-llm01",
  "version": 1,
  "weekStart": ""
}
```

- [x] **Step 2: Verify the file is valid JSON**

Run: `jq . hosts/llm01/amdgpu-dashboard.json > /dev/null && echo "valid JSON"`
Expected: `valid JSON`

- [x] **Step 3: Verify structure (8 panels + 1 row, 4 variables)**

Run:
```bash
jq -r '.panels[] | select(.type != "row") | .title' hosts/llm01/amdgpu-dashboard.json
```
Expected exactly:
```
GPU Utilization
VRAM Used
GPU Busy (current)
Temperature
Power Draw
Core Clock (sclk)
Memory Clock (mclk)
GTT Memory Used
```

Run:
```bash
jq -r '.templating.list[].name' hosts/llm01/amdgpu-dashboard.json
```
Expected exactly:
```
DS_PROMETHEUS
instance
card
chip
```

- [x] **Step 4: Verify queries reference only existing metrics**

Run:
```bash
jq -r '.panels[] | select(.type != "row") | .targets[]?.expr' hosts/llm01/amdgpu-dashboard.json | grep -oE 'node_[a-z_]+' | sort -u
```
Expected:
```
node_drm_gpu_busy_percent
node_drm_memory_gtt_size_bytes
node_drm_memory_gtt_used_bytes
node_drm_memory_vram_size_bytes
node_drm_memory_vram_used_bytes
node_hwmon_chip_names
node_hwmon_freq_freq_mhz
node_hwmon_power_average_watt
node_hwmon_temp_celsius
node_hwmon_temp_crit_celsius
```

- [x] **Step 5: Commit**

```bash
git add hosts/llm01/amdgpu-dashboard.json
git commit -m "feat(llm01): add AMD GPU Grafana dashboard"
```

---

## Self-Review Notes

- **Spec coverage:** All 8 panels from the spec table are present (GPU Utilization, GPU Busy stat, VRAM Used, Temperature + crit line, Power Draw, sclk, mclk, GTT Memory Used). All 4 template variables from the spec table are present. The hwmon join follows the spec's query pattern (join on `(instance, chip)`). Acceptance criteria 1 (import prompt via `__inputs`), 2 (existing metrics only), 3 (amdgpu chip join), 4 (`jq` parses) are each covered by a step.
- **Placeholder scan:** Full JSON is embedded; every target has a concrete `expr` and `legendFormat`; every verification command has expected output.
- **Type consistency:** All queries consistently use `instance=~"$instance"`, `card=~"$card"`, `chip=~"$chip"`, and the same join expression across temp/power/clock panels.
