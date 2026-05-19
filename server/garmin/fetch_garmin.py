#!/usr/bin/env python3
"""
Fetch daily Garmin Connect metrics and write to /data/garmin.json.
Designed to be run by cron, reads credentials from env.
"""
import os
import json
import sys
import datetime
import traceback
from pathlib import Path

try:
    from garminconnect import Garmin
except ImportError:
    print("garminconnect not installed", file=sys.stderr)
    sys.exit(2)

EMAIL = os.environ.get("GARMIN_EMAIL", "").strip()
PASSWORD = os.environ.get("GARMIN_PASSWORD", "").strip()
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
OUT_FILE = DATA_DIR / "garmin.json"
TOKEN_DIR = DATA_DIR / "garmin_tokens"


def log(msg):
    print(f"[{datetime.datetime.now().isoformat(timespec='seconds')}] {msg}", flush=True)


def safe(fn, default=None):
    """Try a Garmin API call, return default on failure (Garmin endpoints fail often)."""
    try:
        return fn()
    except Exception as e:
        log(f"  ! {fn.__name__ if hasattr(fn, '__name__') else 'call'}: {e}")
        return default


def fetch():
    if not EMAIL or not PASSWORD:
        log("FATAL: GARMIN_EMAIL or GARMIN_PASSWORD missing")
        sys.exit(1)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TOKEN_DIR.mkdir(parents=True, exist_ok=True)

    log(f"Logging in as {EMAIL[:3]}***")
    g = Garmin(EMAIL, PASSWORD)
    # Use token cache to avoid hammering Garmin login every run
    try:
        g.login(str(TOKEN_DIR))
    except Exception as e:
        log(f"Token-based login failed ({e}), trying fresh login")
        g = Garmin(EMAIL, PASSWORD)
        g.login()

    today = datetime.date.today()
    yesterday = today - datetime.timedelta(days=1)
    iso_today = today.isoformat()
    iso_yest = yesterday.isoformat()

    result = {
        "fetched_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "date_target": iso_today,
        "yesterday": iso_yest,
        "sleep": None,
        "body_battery": None,
        "stress": None,
        "hrv": None,
        "steps": None,
        "training_readiness": None,
        "training_status": None,
        "last_activity": None,
        "stats": None,
    }

    log("Fetching sleep (yesterday night)…")
    sleep_data = safe(lambda: g.get_sleep_data(iso_today), default=None)
    if sleep_data and isinstance(sleep_data, dict):
        dto = sleep_data.get("dailySleepDTO", {}) or {}
        result["sleep"] = {
            "duration_seconds": dto.get("sleepTimeSeconds"),
            "duration_hours": round((dto.get("sleepTimeSeconds") or 0) / 3600, 2)
            if dto.get("sleepTimeSeconds") else None,
            "score": (dto.get("sleepScores") or {}).get("overall", {}).get("value"),
            "deep_seconds": dto.get("deepSleepSeconds"),
            "light_seconds": dto.get("lightSleepSeconds"),
            "rem_seconds": dto.get("remSleepSeconds"),
            "awake_seconds": dto.get("awakeSleepSeconds"),
            "start": dto.get("sleepStartTimestampLocal"),
            "end": dto.get("sleepEndTimestampLocal"),
        }

    log("Fetching body battery…")
    bb = safe(lambda: g.get_body_battery(iso_today), default=None)
    if bb and isinstance(bb, list) and bb:
        bb_today = bb[0] if isinstance(bb[0], dict) else None
        if bb_today:
            arr = bb_today.get("bodyBatteryValuesArray") or []
            values = [v[1] for v in arr if isinstance(v, list) and len(v) >= 2 and v[1] is not None]
            result["body_battery"] = {
                "charged": bb_today.get("charged"),
                "drained": bb_today.get("drained"),
                "current": values[-1] if values else None,
                "min": min(values) if values else None,
                "max": max(values) if values else None,
            }

    log("Fetching stress…")
    stress = safe(lambda: g.get_stress_data(iso_today), default=None)
    if stress and isinstance(stress, dict):
        result["stress"] = {
            "avg": stress.get("avgStressLevel"),
            "max": stress.get("maxStressLevel"),
            "rest_seconds": stress.get("restStressDuration"),
            "low_seconds": stress.get("lowStressDuration"),
            "medium_seconds": stress.get("mediumStressDuration"),
            "high_seconds": stress.get("highStressDuration"),
        }

    log("Fetching HRV…")
    hrv = safe(lambda: g.get_hrv_data(iso_today), default=None)
    if hrv and isinstance(hrv, dict):
        summary = hrv.get("hrvSummary") or {}
        result["hrv"] = {
            "status": summary.get("status"),
            "feedback_phrase": summary.get("feedbackPhrase"),
            "weekly_avg": summary.get("weeklyAvg"),
            "last_night_avg": summary.get("lastNightAvg"),
            "last_night_5min_high": summary.get("lastNight5MinHigh"),
            "baseline_low_upper": (summary.get("baseline") or {}).get("lowUpper"),
            "baseline_balanced_low": (summary.get("baseline") or {}).get("balancedLow"),
            "baseline_balanced_upper": (summary.get("baseline") or {}).get("balancedUpper"),
        }

    log("Fetching daily stats / steps…")
    stats = safe(lambda: g.get_stats(iso_today), default=None)
    if stats and isinstance(stats, dict):
        result["stats"] = {
            "calories_burned": stats.get("totalKilocalories"),
            "calories_active": stats.get("activeKilocalories"),
            "calories_bmr": stats.get("bmrKilocalories"),
            "intense_minutes": stats.get("vigorousIntensityMinutes"),
            "moderate_minutes": stats.get("moderateIntensityMinutes"),
            "resting_hr": stats.get("restingHeartRate"),
            "max_hr": stats.get("maxHeartRate"),
        }
        result["steps"] = {
            "total": stats.get("totalSteps"),
            "goal": stats.get("dailyStepGoal"),
            "distance_meters": stats.get("totalDistanceMeters"),
        }

    log("Fetching training readiness…")
    tr = safe(lambda: g.get_training_readiness(iso_today), default=None)
    if tr and isinstance(tr, list) and tr:
        latest = tr[0] if isinstance(tr[0], dict) else None
        if latest:
            result["training_readiness"] = {
                "score": latest.get("score"),
                "level": latest.get("level"),
                "feedback_long": latest.get("feedbackLong"),
                "feedback_short": latest.get("feedbackShort"),
                "sleep_score": latest.get("sleepScore"),
                "recovery_time": latest.get("recoveryTime"),
                "hrv_factor_pct": latest.get("hrvFactorPercent"),
                "stress_history_pct": latest.get("stressHistoryFactorPercent"),
            }

    log("Fetching training status…")
    ts = safe(lambda: g.get_training_status(iso_today), default=None)
    if ts and isinstance(ts, dict):
        most = ts.get("mostRecentTrainingStatus") or {}
        latest_per_device = most.get("latestTrainingStatusData") or {}
        if latest_per_device:
            first = next(iter(latest_per_device.values()), {}) or {}
            result["training_status"] = {
                "status": first.get("trainingStatus"),
                "feedback_phrase": first.get("trainingStatusFeedbackPhrase"),
                "vo2_max": first.get("vo2Max"),
                "load_short_term": first.get("acuteTrainingLoadDTO", {}).get("acwrPercent"),
            }

    log("Fetching last activity…")
    acts = safe(lambda: g.get_activities(0, 1), default=None)
    if acts and isinstance(acts, list) and acts:
        a = acts[0]
        result["last_activity"] = {
            "type": (a.get("activityType") or {}).get("typeKey"),
            "name": a.get("activityName"),
            "start_local": a.get("startTimeLocal"),
            "duration_seconds": a.get("duration"),
            "distance_meters": a.get("distance"),
            "calories": a.get("calories"),
            "avg_hr": a.get("averageHR"),
            "max_hr": a.get("maxHR"),
        }

    log(f"Writing {OUT_FILE}")
    tmp = OUT_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    tmp.replace(OUT_FILE)
    log("Done.")


if __name__ == "__main__":
    try:
        fetch()
    except SystemExit:
        raise
    except Exception:
        log("Unhandled exception:")
        traceback.print_exc()
        sys.exit(3)
