#!/usr/bin/env python3
"""Derive VicPlan / Radius demand figures for the POC performance scenarios.

This turns a small set of clearly-stated, editable *behaviour assumptions* into
the load numbers Section 4.10.1 needs:

  * daily sessions,
  * peak-hour concurrent sessions (Little's Law),
  * per-endpoint Lambda request volume and peak requests/second, and
  * suggested concurrency levels for ``api_performance.py``.

IMPORTANT FRAMING
-----------------
Unique-user counts (~7,000 weekday / 2,000 weekend VicPlan users, plus 20-30
weekday Radius users) do NOT by themselves establish concurrent request volume.
The figures produced here are a *modelled scenario* built on stated assumptions,
not measured production demand. They should be labelled that way in the report.
If CloudFront / access-log data becomes available, replace the assumptions below
with observed hourly request rates.

Everything uses the standard library, so it runs without the test venv:

    python demand_model.py
"""

from __future__ import annotations

import csv
import json
from dataclasses import dataclass, field
from pathlib import Path


# --------------------------------------------------------------------------- #
# ASSUMPTIONS - edit these; every downstream number is derived from them.
# --------------------------------------------------------------------------- #
#
# calls_per_session are POPULATION AVERAGES across all sessions (already account
# for the fact that only some users open the query panel). They cover only the
# four Lambda endpoints. Map panning/zooming and layer toggles are served by
# PMTiles from S3/CloudFront, NOT the Lambda API, so they are tracked separately
# under map_actions_per_session for narrative/CDN context only.

LAMBDA_ENDPOINTS = ["list-layers", "describe-layer", "unique-values", "query"]


@dataclass
class Profile:
    name: str
    weekday_users: int
    weekend_users: int
    avg_session_minutes: float          # mean time a user is active on the app
    peak_hour_fraction: float           # share of a day's users in the busiest hour
    calls_per_session: dict             # avg Lambda calls per session, per endpoint
    map_actions_per_session: dict       # PMTiles/CDN interactions (context only)


PROFILES = [
    # VicPlan: high-volume, public, short read-heavy "look something up" sessions.
    # ~30% of sessions are assumed to actually use the query/filter panel; the
    # per-session averages below already fold that engagement rate in.
    Profile(
        name="VicPlan",
        weekday_users=7000,
        weekend_users=2000,
        avg_session_minutes=4.0,
        peak_hour_fraction=0.13,        # public gov sites cluster in a business hour
        calls_per_session={
            "list-layers": 1.0,         # panel loads the layer list once per session
            "describe-layer": 0.6,      # ~30% pick a layer, ~2 describes each
            "unique-values": 2.4,       # ~30% type in the value box, ~8 debounced calls
            "query": 0.9,               # ~30% run ~3 queries
        },
        map_actions_per_session={
            "pan_zoom": 15,             # -> PMTiles tile fetches (CDN, not Lambda)
            "layer_toggle": 3,
        },
    ),
    # Radius: small internal tool, longer working sessions, much heavier query use.
    Profile(
        name="Radius",
        weekday_users=25,               # midpoint of the stated 20-30 weekday users
        weekend_users=0,                # assumed weekday-only internal tool
        avg_session_minutes=15.0,
        peak_hour_fraction=0.20,        # concentrated in working hours
        calls_per_session={
            "list-layers": 1.0,
            "describe-layer": 4.0,
            "unique-values": 20.0,
            "query": 8.0,
        },
        map_actions_per_session={
            "pan_zoom": 40,
            "layer_toggle": 10,
        },
    ),
]

# Assume one session per unique user per day. Bump this if analytics show repeat
# visits within a day.
SESSIONS_PER_USER = 1.0

OUTPUT_DIR = Path("results/demand")


# --------------------------------------------------------------------------- #
# Derivation
# --------------------------------------------------------------------------- #
@dataclass
class DayResult:
    profile: str
    day_type: str
    users: int
    sessions: float
    peak_hour_sessions: float
    avg_session_minutes: float
    peak_concurrent_sessions: float      # Little's Law: arrivals x mean duration
    endpoint_daily_calls: dict = field(default_factory=dict)
    endpoint_peak_hour_calls: dict = field(default_factory=dict)
    endpoint_peak_rps: dict = field(default_factory=dict)
    total_daily_calls: float = 0.0
    total_peak_rps: float = 0.0
    map_daily_actions: dict = field(default_factory=dict)


def derive(profile: Profile, day_type: str) -> DayResult:
    users = profile.weekday_users if day_type == "weekday" else profile.weekend_users
    sessions = users * SESSIONS_PER_USER
    peak_hour_sessions = sessions * profile.peak_hour_fraction
    session_hours = profile.avg_session_minutes / 60.0

    # Little's Law: average number in the system = arrival rate x average time in
    # system. Over the peak hour, arrivals = peak_hour_sessions and each stays
    # session_hours, so mean concurrent sessions ~= peak_hour_sessions * session_hours.
    peak_concurrent = peak_hour_sessions * session_hours

    daily_calls, peak_hour_calls, peak_rps = {}, {}, {}
    for ep in LAMBDA_ENDPOINTS:
        per = profile.calls_per_session.get(ep, 0.0)
        d = sessions * per
        ph = d * profile.peak_hour_fraction
        daily_calls[ep] = d
        peak_hour_calls[ep] = ph
        peak_rps[ep] = ph / 3600.0

    map_daily = {
        action: sessions * count
        for action, count in profile.map_actions_per_session.items()
    }

    return DayResult(
        profile=profile.name,
        day_type=day_type,
        users=users,
        sessions=sessions,
        peak_hour_sessions=peak_hour_sessions,
        avg_session_minutes=profile.avg_session_minutes,
        peak_concurrent_sessions=peak_concurrent,
        endpoint_daily_calls=daily_calls,
        endpoint_peak_hour_calls=peak_hour_calls,
        endpoint_peak_rps=peak_rps,
        total_daily_calls=sum(daily_calls.values()),
        total_peak_rps=sum(peak_rps.values()),
        map_daily_actions=map_daily,
    )


def suggested_concurrency(peak_rps: float) -> list[int]:
    """Turn a peak requests/second figure into sensible api_performance levels.

    We test at baseline (1), around expected peak, and multiples above it to
    demonstrate headroom. Levels are clamped to whole numbers and de-duplicated.
    """
    base = max(1, round(peak_rps))
    levels = sorted({1, base, base * 5, base * 10, 25, 50})
    return [n for n in levels if n <= 100]


# --------------------------------------------------------------------------- #
# Reporting / output
# --------------------------------------------------------------------------- #
def fmt(n: float, places: int = 2) -> str:
    return f"{n:,.{places}f}"


def print_report(results: list[DayResult], combined_weekday: dict) -> None:
    print("=" * 78)
    print("DTP POC - Modelled demand scenario (assumptions, not measured demand)")
    print("=" * 78)

    for r in results:
        if r.users == 0:
            continue
        print(f"\n{r.profile}  ({r.day_type})")
        print(f"  Users / sessions per day        : {r.users:,} / {fmt(r.sessions,0)}")
        print(f"  Mean session length             : {fmt(r.avg_session_minutes,1)} min")
        print(f"  Sessions arriving in peak hour   : {fmt(r.peak_hour_sessions,0)}")
        print(f"  Peak concurrent sessions         : {fmt(r.peak_concurrent_sessions,1)}")
        print(f"  Total Lambda calls / day         : {fmt(r.total_daily_calls,0)}")
        print(f"  Total Lambda peak load           : {fmt(r.total_peak_rps,2)} req/s")
        print("  Per-endpoint (daily | peak req/s):")
        for ep in LAMBDA_ENDPOINTS:
            print(
                f"      {ep:<15} {fmt(r.endpoint_daily_calls[ep],0):>10} | "
                f"{fmt(r.endpoint_peak_rps[ep],3):>8}"
            )
        print("  Map/PMTiles actions / day (CDN, not Lambda):")
        for action, total in r.map_daily_actions.items():
            print(f"      {action:<15} {fmt(total,0):>10}")

    print("\n" + "-" * 78)
    print("COMBINED WEEKDAY PEAK (VicPlan + Radius)")
    print("-" * 78)
    print(f"  Peak concurrent sessions   : {fmt(combined_weekday['peak_concurrent'],1)}")
    print(f"  Total Lambda peak load     : {fmt(combined_weekday['total_peak_rps'],2)} req/s")
    print("  Per-endpoint peak req/s:")
    for ep in LAMBDA_ENDPOINTS:
        print(f"      {ep:<15} {fmt(combined_weekday['endpoint_peak_rps'][ep],3):>8}")
    print(
        f"\n  Suggested api_performance.py concurrency levels: "
        f"{','.join(str(n) for n in combined_weekday['suggested_concurrency'])}"
    )
    print("  (baseline -> expected peak -> multiples above to show headroom)")
    print("=" * 78)


def write_outputs(results: list[DayResult], combined_weekday: dict) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Long-form CSV: one row per profile/day-type/endpoint.
    rows = []
    for r in results:
        for ep in LAMBDA_ENDPOINTS:
            rows.append({
                "profile": r.profile,
                "day_type": r.day_type,
                "users": r.users,
                "sessions": round(r.sessions, 1),
                "peak_hour_sessions": round(r.peak_hour_sessions, 1),
                "peak_concurrent_sessions": round(r.peak_concurrent_sessions, 2),
                "endpoint": ep,
                "daily_calls": round(r.endpoint_daily_calls[ep], 1),
                "peak_hour_calls": round(r.endpoint_peak_hour_calls[ep], 1),
                "peak_rps": round(r.endpoint_peak_rps[ep], 4),
            })
    if rows:
        with (OUTPUT_DIR / "demand_scenarios.csv").open(
            "w", newline="", encoding="utf-8"
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    # Assumptions echoed back for traceability in the report.
    assumptions = [
        {
            "profile": p.name,
            "weekday_users": p.weekday_users,
            "weekend_users": p.weekend_users,
            "avg_session_minutes": p.avg_session_minutes,
            "peak_hour_fraction": p.peak_hour_fraction,
            "calls_per_session": p.calls_per_session,
            "map_actions_per_session": p.map_actions_per_session,
        }
        for p in PROFILES
    ]

    summary = {
        "framing": (
            "Modelled scenario derived from stated behaviour assumptions. "
            "Not measured production demand."
        ),
        "sessions_per_user": SESSIONS_PER_USER,
        "assumptions": assumptions,
        "results": [
            {
                "profile": r.profile,
                "day_type": r.day_type,
                "users": r.users,
                "sessions": round(r.sessions, 1),
                "peak_hour_sessions": round(r.peak_hour_sessions, 1),
                "peak_concurrent_sessions": round(r.peak_concurrent_sessions, 2),
                "total_daily_calls": round(r.total_daily_calls, 1),
                "total_peak_rps": round(r.total_peak_rps, 4),
                "endpoint_peak_rps": {
                    ep: round(r.endpoint_peak_rps[ep], 4) for ep in LAMBDA_ENDPOINTS
                },
                "map_daily_actions": {k: round(v, 1) for k, v in r.map_daily_actions.items()},
            }
            for r in results
        ],
        "combined_weekday_peak": combined_weekday,
    }
    (OUTPUT_DIR / "demand_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(f"\nWrote {OUTPUT_DIR.resolve()}\\demand_scenarios.csv and demand_summary.json")


def main() -> None:
    results = [derive(p, dt) for p in PROFILES for dt in ("weekday", "weekend")]

    weekday = [r for r in results if r.day_type == "weekday"]
    endpoint_peak = {
        ep: round(sum(r.endpoint_peak_rps[ep] for r in weekday), 4)
        for ep in LAMBDA_ENDPOINTS
    }
    total_peak_rps = round(sum(endpoint_peak.values()), 4)
    combined_weekday = {
        "peak_concurrent": round(sum(r.peak_concurrent_sessions for r in weekday), 2),
        "total_peak_rps": total_peak_rps,
        "endpoint_peak_rps": endpoint_peak,
        "suggested_concurrency": suggested_concurrency(total_peak_rps),
    }

    print_report(results, combined_weekday)
    write_outputs(results, combined_weekday)


if __name__ == "__main__":
    main()
