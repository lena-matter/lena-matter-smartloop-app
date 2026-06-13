#!/usr/bin/env python3
"""
Simulate a ThinkLid lid posting fill readings to the ingestion Edge Function.
Useful for testing realtime updates on the dashboard with no hardware.

Usage:
  export FN_URL="https://<project>.functions.supabase.co/thinklid-ingest"
  export DEVICE_KEY="<plaintext key returned by register_thinklid()>"
  python3 simulate_thinklid.py --serial TL-AU-0001 --interval 5

Watch the Live Bin Status page on the dashboard fill in real time.
"""
import argparse, json, os, time, urllib.request, random

def post(url, key, serial, fill, weight):
    body = json.dumps({"serial": serial, "fill_pct": fill, "weight_kg": weight}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", default="TL-AU-0001")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between readings")
    ap.add_argument("--count", type=int, default=0, help="0 = run forever")
    args = ap.parse_args()

    url = os.environ.get("FN_URL"); key = os.environ.get("DEVICE_KEY")
    if not url or not key:
        raise SystemExit("Set FN_URL and DEVICE_KEY environment variables first.")

    fill = random.randint(20, 40); n = 0
    while args.count == 0 or n < args.count:
        fill = max(0, min(100, fill + random.randint(-3, 8)))   # drifts up, occasional empty
        if fill >= 98: fill = random.randint(5, 15)             # bin emptied
        status, resp = post(url, key, args.serial, fill, round(random.uniform(1, 8), 1))
        print(f"[{time.strftime('%H:%M:%S')}] {args.serial} fill={fill:>3}%  -> {status} {resp}")
        n += 1
        time.sleep(args.interval)

if __name__ == "__main__":
    main()
