# DTP POC performance tests

This folder contains two independent test utilities:

- `api_performance.py` measures latency, throughput, response size and errors for the exact Lambda requests supplied in a JSON file.
- `frontend_performance.py` measures browser loading, paint, JavaScript and PMTiles delivery metrics for the POC application.

## Installation

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/playwright install chromium
```

On Windows, use `.venv\Scripts\python.exe` and `.venv\Scripts\playwright.exe`.

## API testing

Copy `requests.example.json` to `requests.json`. Insert the exact request bodies from Postman for `unique-values` and `query`, then set those cases to `"enabled": true`.

Start with a low-volume test:

```bash
python api_performance.py --requests-file requests.json --requests-per-case 10 --concurrency 1,5,10
```

The output includes raw request results and a summary containing mean, p50, p95 and p99 latency, throughput and error rate. Do not run higher concurrency against the AWS environment until the test volume and potential cost have been approved.

## Frontend and map testing

```bash
python frontend_performance.py --cold-runs 5 --warm-runs 5
```

The frontend test records:

- HTTP time to first byte
- First Contentful Paint
- Largest Contentful Paint
- Time until the MapLibre canvas is visible
- Time until PMTiles network activity has settled
- Total Blocking Time
- Cumulative Layout Shift
- PMTiles request count, failures and transferred bytes where exposed by the browser

Cold tests use a new browser context for every run. Warm tests reuse a browser context after an unrecorded initial load so that browser and CDN caching effects can be observed separately.

`pmtiles_network_settled_ms` is an external approximation of map readiness. The most accurate application-specific measurement would be produced by adding a performance mark to the application when the MapLibre map emits its `idle` event, then collecting that mark in this script.

## Recommended document structure

- 4.10 POC Performance Testing
- 4.10.1 Test Scope and Demand Assumptions
- 4.10.2 Application API Performance
- 4.10.3 Frontend and Map Rendering Performance
- 4.10.4 Results and Limitations

Unique-user counts do not directly establish concurrent request volume. The reported 7,000 weekday and 2,000 weekend VicPlan users should be recorded as demand context. Concurrency scenarios should be based on hourly request or CloudFront access data where available; otherwise they must be clearly labelled as test scenarios rather than measured production demand.