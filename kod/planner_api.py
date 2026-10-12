"""Reseplanerare ovanpå MOTIS: sorterar bort dumma förslag, bygger hotellnätter, grupperar sista biten.

Regler (Olles):
- Visa nattåg eller riktig hotellnatt – aldrig en natt på en station.
- Hoppa inte över regionaltåg och bussar: alternativen för sista biten visas.
"""
import json, urllib.request, urllib.parse
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

MOTIS = "http://localhost:8100"
NIGHT_START, NIGHT_END = 23 * 60 + 30, 5 * 60      # lokal tid: 23:30–05:00
HOTEL_MIN_WAIT = 6 * 60                             # minst 6 h för att det ska vara en riktig hotellnatt
HUB_MIN_DEPS = 120                                  # avgångar per dygn för att räknas som stad med hotell
LONG_DAY_WAIT = 4 * 60                              # flagga långa väntetider dagtid
MAIN_LEG_MIN = 90 * 60                              # ben över 90 min räknas som huvudresa

def _get(path, **p):
    return json.load(urllib.request.urlopen(MOTIS + path + "?" + urllib.parse.urlencode(p), timeout=120))

def _t(s): return datetime.fromisoformat(s.replace("Z", "+00:00"))
def _loc(s, tz): return _t(s).astimezone(ZoneInfo(tz or "Europe/Berlin"))

_hub = {}
def is_hub(stop_id, when_iso):
    if stop_id not in _hub:
        try:
            d = _get("/api/v5/stoptimes", stopId=stop_id, time=when_iso, n=HUB_MIN_DEPS)
            st = d.get("stopTimes", [])
            if len(st) < HUB_MIN_DEPS: _hub[stop_id] = False
            else:
                span = _t(st[-1]["place"]["departure"]) - _t(st[0]["place"]["departure"])
                _hub[stop_id] = span <= timedelta(hours=24)
        except Exception:
            _hub[stop_id] = False
    return _hub[stop_id]

def _overlaps_night(a, b):
    """a, b lokala datetimes: täcker intervallet natten 23:30–05:00?"""
    cur = a
    while cur < b:
        m = cur.hour * 60 + cur.minute
        if m >= NIGHT_START or m < NIGHT_END: return True
        cur += timedelta(minutes=15)
    return False

def query(frm, to, time_iso, window=86400, n=12):
    return _get("/api/v5/plan", fromPlace=frm, toPlace=to, time=time_iso, searchWindow=window,
                numItineraries=n, maxTransfers=8, detailedTransfers="false").get("itineraries", [])

def legs(it): return [l for l in it["legs"] if l["mode"] != "WALK"]

def classify(it):
    """Returnerar (status, info). status: ok | hotel | reject."""
    L = legs(it); flags = []; hotel = None
    for a, b in zip(L, L[1:]):
        tz = b["from"].get("tz") or a["to"].get("tz")
        arr, dep = _loc(a["endTime"], tz), _loc(b["startTime"], tz)
        wait = (dep - arr).total_seconds() / 60
        if _overlaps_night(arr, dep) and wait > 60:
            if wait >= HOTEL_MIN_WAIT and is_hub(a["to"]["stopId"], a["endTime"]):
                hotel = {"city": a["to"]["name"], "stopId": a["to"]["stopId"], "in": arr, "out": dep}
            else:
                return "reject", {"reason": f"natt på station i {a['to']['name']} ({int(wait)} min)", "at": a}
        elif wait > LONG_DAY_WAIT:
            flags.append(f"lång väntan i {a['to']['name']} ({wait/60:.1f} h)")
    return ("hotel" if hotel else "ok"), {"hotel": hotel, "flags": flags}

def hotel_variant(it, to):
    """Bryt resan i den sista storstaden man når på kvällen, sov där och åk vidare 07:00."""
    L = legs(it); best = None
    for i, l in enumerate(L[:-1]):
        tz = l["to"].get("tz"); arr = _loc(l["endTime"], tz)
        if 16 <= arr.hour <= 22 and is_hub(l["to"]["stopId"], l["endTime"]):
            best = (i, l, arr)
    if not best: return None
    i, l, arr = best
    morning = (arr + timedelta(days=1)).replace(hour=7, minute=0, second=0)
    nxt = query(l["to"]["stopId"], to, morning.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ"), window=4 * 3600, n=4)
    nxt = [x for x in nxt if classify(x)[0] == "ok"]
    if not nxt: return None
    n0 = min(nxt, key=lambda x: _t(x["endTime"]))
    return {"first": L[: i + 1], "hotel": {"city": l["to"]["name"], "in": arr,
            "out": _loc(legs(n0)[0]["startTime"], legs(n0)[0]["from"].get("tz"))},
            "rest": legs(n0), "startTime": L[0]["startTime"], "endTime": n0["endTime"]}

def main_key(L):
    """Huvudresan = alla ben fram till och med sista långa benet. Sista biten får variera."""
    last = max([i for i, l in enumerate(L) if l["duration"] >= MAIN_LEG_MIN] or [len(L) - 1])
    return tuple((l.get("tripId") or l.get("displayName"), l["startTime"]) for l in L[: last + 1]), last

def plan(frm, to, time_iso, limit=6):
    raw = query(frm, to, time_iso)
    options, rejected, seen_hotel = [], [], set()
    for it in raw:
        st, info = classify(it)
        if st == "reject":
            rejected.append(info["reason"])
            hv = hotel_variant(it, to)
            if hv and (hv["hotel"]["city"], hv["startTime"]) not in seen_hotel:
                seen_hotel.add((hv["hotel"]["city"], hv["startTime"]))
                options.append({"kind": "hotell", "legs": hv["first"] + hv["rest"], "hotel": hv["hotel"],
                                "start": hv["startTime"], "end": hv["endTime"], "flags": []})
            continue
        options.append({"kind": "hotell" if st == "hotel" else _kind(legs(it)),
                        "legs": legs(it), "hotel": info["hotel"], "start": it["startTime"], "end": it["endTime"], "flags": info["flags"]})
    # gruppera: samma huvudresa, olika sista bit (regionaltåg / buss) -> ett förslag med alternativ
    groups = {}
    for o in options:
        k, last = main_key(o["legs"])
        g = groups.setdefault(k, {**o, "tails": [], "last": last})
        g["tails"].append({"legs": o["legs"][last + 1:], "end": o["end"]})
        if _t(o["end"]) < _t(g["end"]): g["end"] = o["end"]
    G = list(groups.values())
    # ta bort förslag som ett annat slår på alla punkter (senare avgång, tidigare framme, inte fler byten)
    def nchg(g): return len(g["legs"]) - 1
    def dominated(g):
        return any(h is not g and _t(h["start"]) >= _t(g["start"]) and _t(h["end"]) <= _t(g["end"])
                   and nchg(h) <= nchg(g) and (h["kind"] != "hotell" or g["kind"] == "hotell")
                   and (_t(h["start"]) > _t(g["start"]) or _t(h["end"]) < _t(g["end"]) or nchg(h) < nchg(g)) for h in G)
    G = [g for g in G if not dominated(g)]
    G.sort(key=lambda g: _t(g["end"]) + timedelta(minutes=20 * nchg(g)))
    return {"options": G[:limit], "rejected": rejected}

def _kind(L):
    ov = [l for l in L if _overnight_leg(l)]
    if not ov: return "dagtåg"
    return "nattbuss" if all(l["mode"] == "BUS" for l in ov) else "nattåg"

def _overnight_leg(l):
    a, b = _loc(l["startTime"], l["from"].get("tz")), _loc(l["endTime"], l["to"].get("tz"))
    return l["duration"] >= 5 * 3600 and _overlaps_night(a, b)

def fmt(res):
    out = []
    for g in res["options"]:
        tz0 = g["legs"][0]["from"].get("tz"); tz1 = g["legs"][-1]["to"].get("tz")
        s, e = _loc(g["start"], tz0), _loc(g["end"], tz1)
        ops = sorted({l.get("agencyName", "?") for l in g["legs"]})
        out.append(f"\n== {g['kind'].upper()}: {s:%a %H:%M} -> {e:%a %H:%M}  ({(e - s).total_seconds()/3600:.1f} h, {len(g['legs'])-1} byten, {len(ops)} bolag)")
        for l in g["legs"][: g["last"] + 1]:
            a, b = _loc(l["startTime"], l["from"].get("tz")), _loc(l["endTime"], l["to"].get("tz"))
            out.append(f"   {a:%a %H:%M} {l['from']['name'][:26]:26} -> {b:%a %H:%M} {l['to']['name'][:26]:26} {(l.get('displayName') or '')[:10]:10} {l.get('agencyName','')[:20]}")
            if g["hotel"] and l["to"]["name"] == g["hotel"]["city"]:
                out.append(f"   *** HOTELLNATT i {g['hotel']['city']} – vidare {g['hotel']['out']:%a %H:%M}")
        for t in sorted(g["tails"], key=lambda t: _t(t["end"])):
            if not t["legs"]: continue
            te = _loc(t["end"], t["legs"][-1]["to"].get("tz"))
            out.append("   sista biten: " + "  +  ".join(f"{_loc(l['startTime'], l['from'].get('tz')):%H:%M} {l['mode'].replace('REGIONAL_RAIL','regionaltåg').replace('BUS','buss')} {l.get('displayName') or ''} till {l['to']['name']}" for l in t["legs"]) + f"  → framme {te:%H:%M}")
        for f in g["flags"]: out.append("   OBS: " + f)
    if res["rejected"]: out.append("\nBortsorterat: " + "; ".join(sorted(set(res["rejected"]))))
    return "\n".join(out)

if __name__ == "__main__":
    import sys
    print(fmt(plan(*sys.argv[1:4])))
