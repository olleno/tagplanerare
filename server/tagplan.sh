#!/bin/bash
# Tågplaneraren på Olles Hetzner-server. Körs som root.
# Första gången: installerar allt. Därefter körs den varje timme av cron och gör:
#  - hämtar senaste versionen av sig själv från Dropbox och kör om den om den ändrats
#  - varje natt 03:xx: laddar ner färska tidtabeller, bygger om och startar om sökmotorn
set -u
SELF_URL="https://raw.githubusercontent.com/olleno/tagplanerare/main/server/tagplan.sh"
SE_URL="https://raw.githubusercontent.com/olleno/tagplanerare/main/data/sverige-gtfs.zip"
D=/opt/tagplan
PORT=8100   # 8080 används av tradingagenten på samma server
mkdir -p $D/in $D/kod $D/logg
exec >>$D/logg/tagplan.log 2>&1
echo "=== $(date -Is) start ($1)"
MODE="${1:-cron}"

# --- självuppdatering ---
if [ "$MODE" = "cron" ]; then
  if curl -fsSL "$SELF_URL" -o $D/kod/ny.sh && ! cmp -s $D/kod/ny.sh $D/kod/tagplan.sh; then
    install -m 755 $D/kod/ny.sh $D/kod/tagplan.sh; echo "ny version hämtad"; exec $D/kod/tagplan.sh install
  fi
fi

install_base() {
  command -v unzip >/dev/null || (apt-get update -qq && apt-get install -y -qq unzip bzip2 curl python3)
  if ! swapon --show | grep -q .; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  if [ ! -x $D/motis ]; then
    curl -fsSL -o /tmp/m.tar.bz2 https://github.com/motis-project/motis/releases/download/v2.11.3/motis-linux-amd64.tar.bz2
    tar xjf /tmp/m.tar.bz2 -C $D && rm /tmp/m.tar.bz2
  fi
  [ -f $D/kod/tagplan.sh ] || install -m 755 "$0" $D/kod/tagplan.sh
  cat > /etc/systemd/system/tagplan.service <<EOF
[Unit]
Description=Tagplaneraren (MOTIS)
After=network.target
[Service]
WorkingDirectory=$D/run
ExecStart=$D/motis server -d $D/run/data
Restart=always
MemoryMax=1500M
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable -q tagplan
  echo "17 * * * * root $D/kod/tagplan.sh cron" > /etc/cron.d/tagplan
  if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow $PORT/tcp; fi
}

write_filter() {
cat > $D/kod/filt.py <<'PY'
import zipfile,csv,io,sys
csv.field_size_limit(10**9)
src,dst=sys.argv[1],sys.argv[2]
z=zipfile.ZipFile(src)
names={n.rsplit('/',1)[-1]:n for n in z.namelist() if not n.endswith('/')}   # tål filer i en undermapp (ÖBB)
def rd(n): return csv.reader(io.TextIOWrapper(z.open(names[n]),'utf-8-sig',newline=''))
rail=lambda t: t in('1','2') or (t.isdigit() and (100<=int(t)<=117 or 400<=int(t)<=405))
out=zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED)
def stream(n,keep):  # skriver raderna där keep(rad) är sant, utan att hålla filen i minnet
    with out.open(n,'w',force_zip64=True) as f:
        t=io.TextIOWrapper(f,'utf-8',newline='');cw=csv.writer(t,lineterminator='\n')
        r=rd(n);h=next(r);cw.writerow(h);k=keep(h)
        for x in r:
            if k(x): cw.writerow(x)
        t.flush();t.detach()
keep_r=set();keep_t=set();keep_s=set();stops=set()
def f_routes(h):
    it=h.index('route_type');ir=h.index('route_id')
    isn=h.index('route_short_name') if 'route_short_name' in h else None;ide=h.index('route_desc') if 'route_desc' in h else None
    def ersatz(x):  # ersättningsbuss för tåg: Schweiz märker dem "EV", Tyskland "SEV"
        return (ide is not None and x[ide].strip().upper()=='EV') or (isn is not None and x[isn].strip().upper().startswith('SEV'))
    def k(x):
        if rail(x[it]) or ersatz(x): keep_r.add(x[ir]);return True
    return k
def f_trips(h):
    ir=h.index('route_id');itr=h.index('trip_id');isv=h.index('service_id')
    def k(x):
        if x[ir] in keep_r: keep_t.add(x[itr]);keep_s.add(x[isv]);return True
    return k
def f_st(h):
    a=h.index('trip_id');s=h.index('stop_id')
    def k(x):
        if x[a] in keep_t: stops.add(x[s]);return True
    return k
stream('routes.txt',f_routes);stream('trips.txt',f_trips);stream('stop_times.txt',f_st)
r=rd('stops.txt');h=next(r);i=h.index('stop_id');p=h.index('parent_station') if 'parent_station' in h else None
rows=list(r);par={x[p] for x in rows if p is not None and x[i] in stops and x[p]}
b=io.StringIO();csv.writer(b,lineterminator='\n').writerows([h]+[x for x in rows if x[i] in stops or x[i] in par]);out.writestr('stops.txt',b.getvalue())
for n in ('calendar.txt','calendar_dates.txt'):
    if n in names: stream(n,lambda h:(lambda k:lambda x:x[k] in keep_s)(h.index('service_id')))
for n in ('agency.txt','feed_info.txt','attributions.txt'):
    if n in names: out.writestr(n,z.read(names[n]))
out.close()
PY
}

set_port() {  # set_port <data-mapp>: sökmotorn lyssnar på $PORT
  [ -f "$1/config.yml" ] || return 0
  sed -i '/^server:/,/^[^ ]/{/^server:/d;/^  /d}' "$1/config.yml"
  printf 'server:\n  host: 0.0.0.0\n  port: %s\n' "$PORT" >> "$1/config.yml"
}

# --- söksidan (port 8110, lösenord i $D/sok.losen) ---
# Kopior av kod/planner_api.py och kod/sok.py – ändras de där måste de klistras in här igen.
install_web() {
cat > $D/kod/planner_api.py <<'PYEOF'
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
PYEOF
cat > $D/kod/sok.py <<'PYEOF'
"""Enkel söksida ovanpå planner_api: välj två orter, datum och tid – få Olles sorterade förslag.

Körs:  python3 sok.py [GTFS-katalog] [port] [lösenordsfil]   (standard: /opt/tagplan/in 8110 /opt/tagplan/sok.losen)
Lösenordsskydd: valfritt användarnamn, lösenordet står i lösenordsfilen. Saknas filen är sidan öppen.
Stationslistan byggs från stops.txt i GTFS-filerna; MOTIS stopp-id blir "<dataset>_<stop_id>".
Landet vid varje station tas från koordinaterna och landsgränserna i <GTFS-katalog>/lander.json, som skapas med
  python3 sok.py --lander ne_10m_admin_0_countries.geojson <GTFS-katalog>/lander.json   (Natural Earth, fri att använda)
"""
import base64, csv, hmac, io, json, os, sys, unicodedata, zipfile
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import planner_api as P

if __name__ == "__main__" and sys.argv[1:2] == ["--lander"]:   # gör om Natural Earth-filen till en liten Europa-fil
    feats = [f for f in json.load(open(sys.argv[2]))["features"] if f["properties"].get("CONTINENT") == "Europe"]
    out = []
    for f in feats:
        g = f["geometry"]; polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        rings = [[[round(x, 4), round(y, 4)] for x, y in poly[0]] for poly in polys]   # bara yttre gränsen
        xs = [x for r in rings for x, _ in r]; ys = [y for r in rings for _, y in r]
        out.append({"name": f["properties"]["NAME_SV"], "bbox": [min(xs), min(ys), max(xs), max(ys)], "rings": rings})
    out.sort(key=lambda c: (c["bbox"][2] - c["bbox"][0]) * (c["bbox"][3] - c["bbox"][1]))   # små länder först (San Marino före Italien)
    json.dump(out, open(sys.argv[3], "w")); print(len(out), "länder sparade"); sys.exit()

GTFS_DIR = sys.argv[1] if len(sys.argv) > 1 else "/opt/tagplan/in"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8110
PW_FILE = sys.argv[3] if len(sys.argv) > 3 else "/opt/tagplan/sok.losen"
PASSWORD = open(PW_FILE).read().strip() if os.path.exists(PW_FILE) else None
DATASETS = ("se", "dk", "de", "it", "sta", "at", "ch")
LAND = {"se": "Sverige", "dk": "Danmark", "de": "Tyskland", "it": "Italien", "sta": "Italien", "at": "Österrike", "ch": "Schweiz"}
HOME_TZ = "Europe/Stockholm"
HUB_WORDS = {"c", "central", "centralstation", "hbf", "hauptbahnhof", "h", "centrale", "termini", "hovedbanegard"}

def _norm(s):
    s = s.lower().translate(str.maketrans({"ø": "o", "æ": "ae", "ß": "ss"}))
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))

def load_stations():
    """En rad per station: föräldrastationer, eller hållplatser utan förälder. Plattformar hoppas över."""
    out = []
    for ds in DATASETS:
        p = os.path.join(GTFS_DIR, ds + ".zip")
        if not os.path.exists(p): continue
        with zipfile.ZipFile(p) as z:
            rows = list(csv.DictReader(io.TextIOWrapper(z.open("stops.txt"), "utf-8-sig", newline="")))
        kids = {}
        for x in rows:
            if x.get("parent_station"): kids[x["parent_station"]] = kids.get(x["parent_station"], 0) + 1
        for x in rows:
            if x.get("parent_station") or x.get("location_type", "") not in ("", "0", "1"): continue
            n = _norm(x["stop_name"])
            big = kids.get(x["stop_id"], 0) + (20 if HUB_WORDS & set(n.replace(",", " ").replace("(", " ").split()) else 0)
            try: pos = (float(x["stop_lon"]), float(x["stop_lat"]))
            except (KeyError, ValueError): pos = None
            out.append({"id": f"{ds}_{x['stop_id']}", "name": x["stop_name"], "ds": ds, "pos": pos, "big": big, "n": n})
    print(f"{len(out)} stationer inlästa från {GTFS_DIR}", flush=True)
    return out

STATIONS = load_stations()

try: COUNTRIES = json.load(open(os.path.join(GTFS_DIR, "lander.json")))
except Exception: COUNTRIES = []

def _inside(x, y, ring):
    hit = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1): hit = not hit
    return hit

def country(s):
    """Landet stationen ligger i (räknas ut först när stationen visas). Utanför kartan: tidtabellens land."""
    if "land" not in s:
        s["land"] = LAND[s["ds"]]
        if s["pos"]:
            x, y = s["pos"]
            for c in COUNTRIES:
                b = c["bbox"]
                if b[0] <= x <= b[2] and b[1] <= y <= b[3] and any(_inside(x, y, r) for r in c["rings"]):
                    s["land"] = c["name"]; break
    return s["land"]

def search_stations(q, n=12):
    q = _norm(q.strip())
    if len(q) < 2: return []
    hits = []
    for s in STATIONS:
        i = s["n"].find(q)
        if i < 0: continue
        word_start = i == 0 or not s["n"][i - 1].isalnum()
        hits.append(((0 if s["n"] == q else 1 if i == 0 else 2 if word_start else 3),
                     -s["big"], len(s["name"]), s["name"], s))
    hits.sort(key=lambda h: h[:4])
    seen, res = set(), []
    for *_, s in hits:
        k = (s["n"], country(s))
        if k in seen: continue
        seen.add(k); res.append({"id": s["id"], "name": s["name"], "land": s["land"]})
        if len(res) >= n: break
    return res

DAGAR = ("mån", "tis", "ons", "tor", "fre", "lör", "sön")
def _dag(d): return f"{DAGAR[d.weekday()]} {d.day}/{d.month} {d:%H:%M}"
def _hm(iso, tz): return _dag(P._loc(iso, tz))

def _ms(iso): return int(P._t(iso).timestamp() * 1000)

def _leg(l):
    a, b = P._loc(l["startTime"], l["from"].get("tz")), P._loc(l["endTime"], l["to"].get("tz"))
    return {"from": l["from"]["name"], "to": l["to"]["name"], "dep": _dag(a), "arr": _dag(b),
            "train": l.get("displayName") or "", "agency": l.get("agencyName") or "", "url": l.get("agencyUrl") or "",
            "mode": l["mode"], "day": a.strftime("%Y-%m-%d"), "t0": _ms(l["startTime"]), "t1": _ms(l["endTime"]),
            "hm0": a.strftime("%H:%M"), "hm1": b.strftime("%H:%M"), "d0": a.strftime("%Y-%m-%d"), "d1": b.strftime("%Y-%m-%d"),
            "track0": l["from"].get("track") or l["from"].get("scheduledTrack") or "",
            "track1": l["to"].get("track") or l["to"].get("scheduledTrack") or ""}

def to_json(res):
    opts = []
    for g in res["options"]:
        L = g["legs"]; tz0, tz1 = L[0]["from"].get("tz"), L[-1]["to"].get("tz")
        s, e = P._loc(g["start"], tz0), P._loc(g["end"], tz1)
        tails = []
        for t in sorted(g["tails"], key=lambda t: P._t(t["end"])):
            if t["legs"]: tails.append({"legs": [_leg(l) for l in t["legs"]], "arr": _hm(t["end"], t["legs"][-1]["to"].get("tz")), "t1": _ms(t["end"])})
        h = g["hotel"]
        opts.append({"kind": g["kind"], "dep": _dag(s), "arr": _dag(e),
                     "hours": round((e - s).total_seconds() / 3600, 1), "changes": len(L) - 1,
                     "legs": [_leg(l) for l in L[: g["last"] + 1]], "all": [_leg(l) for l in L], "tails": tails, "flags": g["flags"],
                     "hotel": h and {"city": h["city"], "out": _dag(h["out"])},
                     "t0": _ms(g["start"]), "t1": _ms(g["end"]), "hm0": s.strftime("%H:%M"), "hm1": e.strftime("%H:%M"),
                     "d0": s.strftime("%Y-%m-%d"), "d1": e.strftime("%Y-%m-%d")})
    return {"options": opts, "rejected": sorted(set(res["rejected"]))}

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def _authorized(self):
        if not PASSWORD: return True
        h = self.headers.get("Authorization", "")
        try: pw = base64.b64decode(h[6:]).decode().partition(":")[2] if h.startswith("Basic ") else ""
        except Exception: pw = ""
        return hmac.compare_digest(pw.encode(), PASSWORD.encode())

    def do_GET(self):
        if not self._authorized():
            self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="Tagplaneraren", charset="UTF-8"')
            self.send_header("Content-Length", "0"); self.end_headers(); return
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if u.path == "/api/stationer":
            return self._send(200, json.dumps(search_stations(q.get("q", "")), ensure_ascii=False))
        if u.path == "/api/sok":
            try:
                when = datetime.fromisoformat(f"{q['datum']}T{q['tid']}").replace(tzinfo=ZoneInfo(HOME_TZ))
                iso = when.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")
                return self._send(200, json.dumps(to_json(P.plan(q["fran"], q["till"], iso)), ensure_ascii=False))
            except KeyError as e:
                return self._send(400, json.dumps({"error": f"saknar {e}"}))
            except Exception as e:
                return self._send(502, json.dumps({"error": f"{type(e).__name__}: {e}"}, ensure_ascii=False))
        self._send(404, '{"error":"finns inte"}')

    def log_message(self, fmt, *a): print(self.address_string(), fmt % a, flush=True)

PAGE = r"""<!doctype html>
<html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tågplaneraren</title>
<meta name="robots" content="noindex">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%231c3d5a'/%3E%3Cpath d='M10 8h12a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H10a3 3 0 0 1-3-3v-9a3 3 0 0 1 3-3zm0 4v4h12v-4zm1 7a1.5 1.5 0 1 0 0 .01zm10 0a1.5 1.5 0 1 0 0 .01zM11 23l-2 3m12-3 2 3' fill='%23fff' stroke='%23fff' stroke-width='1.2'/%3E%3C/svg%3E">
<style>
:root{
  --bg:#f3f1ec;--surface:#fff;--surface2:#f8f7f3;--fg:#1b1d21;--mut:#686c73;--faint:#9a9ea5;--line:#e4e1d9;
  --brand:#1c3d5a;--brand2:#285a82;--accent:#d9622b;--ok:#2f7d4f;--warn:#b5621a;
  --c-fast:#2563a8;--c-reg:#2a8f86;--c-night:#4a3f9c;--c-bus:#d08a1c;--c-other:#7b8794;--c-hotel:#8a4fb8;
  --shadow:0 1px 2px rgba(20,24,30,.06),0 4px 16px rgba(20,24,30,.06);--r:14px}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --bg:#121417;--surface:#1b1e23;--surface2:#22262c;--fg:#eceef1;--mut:#a3a8b0;--faint:#757b84;--line:#2e333a;
  --brand:#0f2133;--brand2:#7fb4e3;--accent:#f08a54;--ok:#6cc596;--warn:#e7a35d;
  --c-fast:#5c9be0;--c-reg:#4fc0b5;--c-night:#8f84e6;--c-bus:#e8aa45;--c-other:#98a3ae;--c-hotel:#c08ae6;
  --shadow:0 1px 2px rgba(0,0,0,.3),0 6px 20px rgba(0,0,0,.25)}}
*{box-sizing:border-box}
html,body{margin:0}
body{background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;-webkit-font-smoothing:antialiased}
button,input{font:inherit;color:inherit}
.hero{background:linear-gradient(135deg,#16324b 0%,#1c3d5a 45%,#2b5878 100%);color:#fff;padding:28px 16px 84px;position:relative;overflow:hidden}
.hero::after{content:"";position:absolute;inset:auto -10% -40px -10%;height:120px;background:radial-gradient(60% 100% at 50% 0,rgba(255,255,255,.08),transparent)}
.wrap{max-width:880px;margin:0 auto}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:20px;letter-spacing:-.01em}
.brand svg{flex:none}
.hero p{margin:6px 0 0 42px;color:rgba(255,255,255,.72);font-size:14px}
main{max-width:880px;margin:-60px auto 60px;padding:0 16px;position:relative;z-index:1}
.search{background:var(--surface);border-radius:18px;box-shadow:var(--shadow);padding:18px;display:grid;gap:12px}
.places{display:grid;grid-template-columns:1fr auto 1fr;gap:10px;align-items:end}
.field{display:flex;flex-direction:column;gap:5px;position:relative;min-width:0}
.field>span{font-size:12px;font-weight:600;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.field input{width:100%;padding:12px 14px;border:1.5px solid var(--line);border-radius:11px;background:var(--surface2);outline:none;transition:border-color .15s,background .15s}
.field input:focus{border-color:var(--brand2);background:var(--surface)}
.swap{width:42px;height:42px;border-radius:50%;border:1.5px solid var(--line);background:var(--surface);cursor:pointer;display:grid;place-items:center;margin-bottom:2px;transition:transform .25s,border-color .15s}
.swap:hover{border-color:var(--brand2);transform:rotate(180deg)}
.when{display:grid;grid-template-columns:1fr 130px auto;gap:10px;align-items:end}
.chips{display:flex;gap:6px;flex-wrap:wrap;grid-column:1/-1;margin-top:-2px}
.chip{border:1px solid var(--line);background:var(--surface);border-radius:999px;padding:4px 11px;font-size:13px;cursor:pointer;color:var(--mut)}
.chip:hover{color:var(--fg);border-color:var(--faint)}
.chip.on{background:var(--brand);border-color:var(--brand);color:#fff}
.go{height:46px;padding:0 26px;border:0;border-radius:11px;background:var(--accent);color:#fff;font-weight:700;cursor:pointer;display:flex;align-items:center;gap:8px;box-shadow:0 2px 8px rgba(217,98,43,.3)}
.go:disabled{opacity:.6;cursor:wait}
.sug{position:absolute;top:calc(100% + 4px);left:0;right:0;z-index:20;background:var(--surface);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);max-height:320px;overflow:auto;display:none;padding:4px}
.sug div{padding:9px 10px;border-radius:8px;cursor:pointer;display:flex;justify-content:space-between;gap:10px}
.sug div small{color:var(--faint);white-space:nowrap}
.sug div.on,.sug div:hover{background:var(--surface2)}
.bar-head{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin:26px 2px 12px}
.bar-head h2{margin:0;font-size:17px;letter-spacing:-.01em}
.bar-head h2 small{display:block;font-weight:400;color:var(--mut);font-size:13px;margin-top:2px}
.seg{display:flex;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:3px;gap:2px}
.seg button{border:0;background:none;padding:6px 10px;border-radius:7px;font-size:13px;color:var(--mut);cursor:pointer}
.seg button.on{background:var(--brand);color:#fff}
.card{background:var(--surface);border-radius:var(--r);box-shadow:var(--shadow);margin-bottom:12px;overflow:hidden;border:1px solid transparent;transition:border-color .15s}
.card:hover{border-color:var(--line)}
.sum{padding:16px 18px 14px;cursor:pointer;display:grid;gap:12px}
.top{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
.times{font-size:24px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
.times .arrow{color:var(--faint);font-weight:400}
.times sup{font-size:12px;color:var(--accent);font-weight:700;margin-left:1px}
.meta{color:var(--mut);font-size:13.5px;margin-top:3px}
.meta b{color:var(--fg);font-weight:600}
.badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:700;padding:5px 10px;border-radius:999px;white-space:nowrap;background:var(--surface2);color:var(--mut)}
.badge.nattåg{background:color-mix(in srgb,var(--c-night) 14%,transparent);color:var(--c-night)}
.badge.hotell{background:color-mix(in srgb,var(--c-hotel) 14%,transparent);color:var(--c-hotel)}
.badge.dagtåg{background:color-mix(in srgb,var(--c-fast) 12%,transparent);color:var(--c-fast)}
.badge.nattbuss{background:color-mix(in srgb,var(--c-bus) 16%,transparent);color:var(--c-bus)}
.track{position:relative;height:10px;border-radius:99px;background:repeating-linear-gradient(90deg,var(--line) 0 4px,transparent 4px 7px)}
.track i{position:absolute;top:0;bottom:0;border-radius:99px;min-width:3px}
.track i.h{background:repeating-linear-gradient(45deg,var(--c-hotel) 0 3px,color-mix(in srgb,var(--c-hotel) 40%,transparent) 3px 6px)}
.ends{display:flex;justify-content:space-between;font-size:12.5px;color:var(--mut);gap:10px}
.ends span:last-child{text-align:right}
.ops{display:flex;flex-wrap:wrap;gap:6px}
.op{font-size:12px;padding:3px 8px;border-radius:6px;background:var(--surface2);color:var(--mut);display:inline-flex;align-items:center;gap:6px}
.op::before{content:"";width:8px;height:8px;border-radius:2px;background:var(--dot,var(--c-other))}
.more{font-size:13px;color:var(--brand2);font-weight:600;display:flex;align-items:center;gap:4px}
.more svg{transition:transform .2s}
.card.open .more svg{transform:rotate(180deg)}
.det{display:none;border-top:1px solid var(--line);padding:6px 18px 16px;background:var(--surface2)}
.card.open .det{display:block}
.tl{list-style:none;margin:10px 0 0;padding:0}
.st{display:grid;grid-template-columns:52px 22px 1fr;align-items:center;min-height:30px}
.st .t{font-weight:700;font-variant-numeric:tabular-nums;font-size:14px}
.st .t small{display:block;font-weight:400;color:var(--faint);font-size:11px;line-height:1}
.st .n{font-weight:600}
.st .n small{color:var(--faint);font-weight:400;margin-left:6px}
.dot{width:12px;height:12px;border-radius:50%;border:2.5px solid var(--col,var(--fg));background:var(--surface);justify-self:center;z-index:1}
.ride{display:grid;grid-template-columns:52px 22px 1fr;min-height:44px}
.ride .ln{justify-self:center;width:4px;border-radius:2px;background:var(--col)}
.ride .info{padding:6px 0;font-size:13.5px;color:var(--mut);display:flex;flex-wrap:wrap;gap:4px 10px;align-items:center}
.tn{font-weight:700;color:#fff;background:var(--col);padding:2px 8px;border-radius:6px;font-size:12.5px}
.xfer{display:grid;grid-template-columns:52px 22px 1fr;min-height:34px}
.xfer .ln{justify-self:center;width:0;border-left:3px dotted var(--faint)}
.xfer .info{font-size:13px;color:var(--mut);display:flex;align-items:center;gap:6px}
.xfer.tight .info{color:var(--warn);font-weight:600}
.xfer.hotel .ln{border-left-color:var(--c-hotel)}
.xfer.hotel .info{color:var(--c-hotel);font-weight:700}
.tails{margin-top:14px;padding:12px 14px;background:var(--surface);border:1px solid var(--line);border-radius:11px}
.tails h4,.prices h4{margin:0 0 8px;font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut)}
.tail{font-size:13.5px;padding:5px 0;display:flex;justify-content:space-between;gap:12px;border-top:1px solid var(--line)}
.tail:first-of-type{border-top:0}
.tail b{font-variant-numeric:tabular-nums}
.flag{margin-top:10px;font-size:13px;color:var(--warn);display:flex;gap:6px;align-items:flex-start}
.prices{margin-top:14px}
.plist{display:flex;flex-wrap:wrap;gap:8px}
.plist a{display:inline-flex;align-items:center;gap:6px;text-decoration:none;font-size:13px;font-weight:600;padding:8px 12px;border-radius:9px;border:1px solid var(--line);background:var(--surface);color:var(--fg)}
.plist a:hover{border-color:var(--brand2)}
.plist a.sj{background:var(--brand);border-color:var(--brand);color:#fff}
.plist a small{font-weight:400;opacity:.75}
.msg{text-align:center;color:var(--mut);padding:40px 16px}
.msg b{display:block;color:var(--fg);font-size:16px;margin-bottom:4px}
.skel{height:150px;border-radius:var(--r);margin-bottom:12px;background:linear-gradient(90deg,var(--surface) 0%,var(--surface2) 50%,var(--surface) 100%);background-size:200% 100%;animation:sh 1.3s infinite linear}
@keyframes sh{to{background-position:-200% 0}}
details.rej{margin-top:18px;font-size:13px;color:var(--mut)}
details.rej summary{cursor:pointer}
details.rej ul{margin:8px 0 0;padding-left:18px}
.legend{display:flex;flex-wrap:wrap;gap:12px;font-size:12px;color:var(--mut);margin:-4px 2px 12px}
.legend span{display:inline-flex;align-items:center;gap:5px}
.legend span::before{content:"";width:14px;height:6px;border-radius:9px;background:var(--dot)}
footer{max-width:880px;margin:0 auto 30px;padding:0 16px;font-size:12px;color:var(--faint);text-align:center}
@media (max-width:640px){
  .places{grid-template-columns:1fr}
  .swap{justify-self:end;margin:-6px 4px -6px 0;width:36px;height:36px;transform:rotate(90deg)}
  .swap:hover{transform:rotate(270deg)}
  .when{grid-template-columns:1fr 1fr}
  .go{grid-column:1/-1;justify-content:center;order:2}
  .chips{order:1}
  .times{font-size:21px}
  .seg button{padding:6px 8px;font-size:12px}
}
</style></head><body>
<header class="hero"><div class="wrap">
  <div class="brand"><svg width="32" height="32" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="9" fill="rgba(255,255,255,.14)"/><path d="M10 7h12a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H10a3 3 0 0 1-3-3v-9a3 3 0 0 1 3-3z" fill="none" stroke="#fff" stroke-width="1.8"/><path d="M8 13h16" stroke="#fff" stroke-width="1.8"/><circle cx="11.5" cy="18" r="1.4" fill="#fff"/><circle cx="20.5" cy="18" r="1.4" fill="#fff"/><path d="M11 22l-2.5 4M21 22l2.5 4" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/></svg>Tågplaneraren</div>
  <p>Tåg genom Europa – nattåg eller riktig hotellnatt, aldrig en natt på perrongen.</p>
</div></header>
<main>
<form class="search" id="f" autocomplete="off">
  <div class="places">
    <label class="field"><span>Från</span><input id="fran" placeholder="Stad eller station" required><div class="sug"></div></label>
    <button type="button" class="swap" id="sw" title="Byt håll" aria-label="Byt håll"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4 3 8l4 4M3 8h14M17 20l4-4-4-4M21 16H7"/></svg></button>
    <label class="field"><span>Till</span><input id="till" placeholder="Stad eller station" required><div class="sug"></div></label>
  </div>
  <div class="when">
    <label class="field"><span>Datum</span><input id="datum" type="date" required></label>
    <label class="field"><span>Avgång efter</span><input id="tid" type="time" value="08:00" required></label>
    <button class="go" id="go"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>Sök resa</button>
    <div class="chips" id="chips"></div>
  </div>
</form>
<div id="out"></div>
</main>
<footer>Tidtabeller: Trafiklab/Samtrafiken, Rejseplanen, DELFI/gtfs.de, Trenitalia, STA, ÖBB, opentransportdata.swiss · Tider i lokal tid vid varje station</footer>
<script>
const $=s=>document.querySelector(s), esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const pick={fran:null,till:null}; let last=null, sortBy='arr';
const DAG=['sön','mån','tis','ons','tor','fre','lör'], MAN=['jan','feb','mar','apr','maj','jun','jul','aug','sep','okt','nov','dec'];
const iso=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
const pretty=s=>{const d=new Date(s+'T12:00');return `${DAG[d.getDay()]} ${d.getDate()} ${MAN[d.getMonth()]}`};
const dur=m=>{m=Math.round(m);const h=Math.floor(m/60),r=m%60;return h?`${h} h${r?` ${r} min`:''}`:`${r} min`};
const dayDiff=(a,b)=>Math.round((new Date(b+'T12:00')-new Date(a+'T12:00'))/864e5);
// datumknappar
const today=new Date(); $('#datum').value=iso(new Date(+today+864e5));
const CH=[['Idag',0],['Imorgon',1],['Om en vecka',7]];
$('#chips').innerHTML=CH.map(([t,n])=>`<button type="button" class="chip" data-n="${n}">${t}</button>`).join('');
const markChips=()=>document.querySelectorAll('#chips .chip').forEach(c=>c.classList.toggle('on',$('#datum').value==iso(new Date(+today+c.dataset.n*864e5))));
$('#chips').onclick=e=>{const c=e.target.closest('.chip');if(!c)return;$('#datum').value=iso(new Date(+today+c.dataset.n*864e5));markChips()};
$('#datum').onchange=markChips; markChips();
try{const p=JSON.parse(localStorage.getItem('senaste')||'null');if(p&&p.fran&&p.till){for(const k of['fran','till']){pick[k]=p[k];$('#'+k).value=p[k].name}}}catch(e){}
// stationsförslag
for(const k of['fran','till']){
  const inp=$('#'+k), box=inp.nextElementSibling; let items=[], on=-1, timer;
  const show=()=>{box.innerHTML=items.map((s,i)=>`<div class="${i==on?'on':''}" data-i="${i}"><span>${esc(s.name)}</span><small>${esc(s.land)}</small></div>`).join('');box.style.display=items.length?'block':'none'};
  const choose=i=>{pick[k]=items[i];inp.value=items[i].name;items=[];show()};
  inp.addEventListener('input',()=>{pick[k]=null;clearTimeout(timer);timer=setTimeout(async()=>{
    try{items=await (await fetch('/api/stationer?q='+encodeURIComponent(inp.value))).json()}catch(e){items=[]}
    on=items.length?0:-1;show()},140)});
  inp.addEventListener('focus',()=>inp.select());
  inp.addEventListener('keydown',e=>{if(!items.length)return;
    if(e.key=='ArrowDown'){on=(on+1)%items.length;show();e.preventDefault()}
    else if(e.key=='ArrowUp'){on=(on-1+items.length)%items.length;show();e.preventDefault()}
    else if(e.key=='Enter'){choose(Math.max(on,0));e.preventDefault()}
    else if(e.key=='Escape'){items=[];show()}});
  box.addEventListener('mousedown',e=>{const d=e.target.closest('[data-i]');if(d){choose(+d.dataset.i);e.preventDefault()}});
  inp.addEventListener('blur',()=>setTimeout(()=>{if(items.length&&!pick[k])choose(0);items=[];show()},120));
}
$('#sw').onclick=()=>{[pick.fran,pick.till]=[pick.till,pick.fran];[$('#fran').value,$('#till').value]=[$('#till').value,$('#fran').value]};
// färger och namn per trafikslag
const MODE={HIGHSPEED_RAIL:['fast','Fjärrtåg'],LONG_DISTANCE:['fast','Fjärrtåg'],RAIL:['fast','Tåg'],NIGHT_RAIL:['night','Nattåg'],
  REGIONAL_FAST_RAIL:['reg','Regionaltåg'],REGIONAL_RAIL:['reg','Regionaltåg'],SUBURBAN:['reg','Pendeltåg'],METRO:['other','Tunnelbana'],SUBWAY:['other','Tunnelbana'],
  TRAM:['other','Spårvagn'],BUS:['bus','Buss'],COACH:['bus','Långfärdsbuss'],FERRY:['other','Färja'],FUNICULAR:['other','Bergbana'],AERIAL_LIFT:['other','Linbana']};
const night=l=>l.t1-l.t0>=5*36e5&&(+l.hm0.slice(0,2)>=19||+l.hm1.slice(0,2)<=9);
const kind=l=>{const k=(MODE[l.mode]||['other'])[0];return k!='bus'&&night(l)?'night':k=='reg'&&l.t1-l.t0>=3*36e5?'fast':k};
const col=l=>`var(--c-${kind(l)})`;
const modeName=l=>({night:'Nattåg',fast:(MODE[l.mode]||[])[0]=='fast'?MODE[l.mode][1]:'Fjärrtåg'})[kind(l)]||(MODE[l.mode]||['','Tåg'])[1];
const nm=n=>String(n||'').replace(/^([^,]+), (\1\b.*)$/,'$2');
const bolag=a=>a.replace(/ \((bvz|fo|Codesharing)\)/,'').replace(/ (AG|AB|SpA|S\.p\.A\.|GmbH|A\/S)\b.*$/,'').replace(' Personenverkehr','').replace(' Kundenservice','').trim();
const KIND={dagtåg:['☀︎','Dagtåg'],nattåg:['☾','Nattåg'],hotell:['⌂','Hotellnatt'],nattbuss:['☾','Nattbuss']};
// prislänkar: SJ visar dagens pris direkt; övriga bolag öppnar sin egen sida
const SJ_SALJER=/^(SJ|Öresundståg|Skånetrafiken|Norrtåg|Mälartåg|Västtågen|Krösatågen|Tåg i Bergslagen)\b/i;
const sjNamn=n=>n.replace(/\s+Centralstation$/,' Central').replace(/\s+C$/,' Central').replace(/^København H$/,'Köpenhamn H');
function prisLankar(legs){
  const out=[]; let i=0;
  while(i<legs.length){
    if(SJ_SALJER.test(legs[i].agency)){let j=i;while(j+1<legs.length&&SJ_SALJER.test(legs[j+1].agency))j++;
      out.push({sj:1,t:`SJ`,s:`${sjNamn(legs[i].from)} – ${sjNamn(legs[j].to)}, pris direkt`,u:`https://www.sj.se/sok-resa/valj-resa/${encodeURIComponent(sjNamn(legs[i].from))}/${encodeURIComponent(sjNamn(legs[j].to))}/${legs[i].day}`});i=j+1}
    else{if(legs[i].url&&!out.some(o=>o.u==legs[i].url))out.push({t:legs[i].agency,s:'bolagets sida',u:legs[i].url});i++}
  }
  return out.length?`<div class="prices"><h4>Priser och biljetter</h4><div class="plist">${out.map(o=>`<a class="${o.sj?'sj':''}" href="${esc(o.u)}" target="_blank" rel="noopener">${esc(o.t)} <small>${esc(o.s)}</small> ↗</a>`).join('')}</div></div>`:'';
}
function card(o,idx){
  const L=o.all, T0=o.t0, span=Math.max(o.t1-T0,1), dd=dayDiff(o.d0,o.d1);
  const segs=L.map(l=>`<i style="left:${(l.t0-T0)/span*100}%;width:${(l.t1-l.t0)/span*100}%;background:${col(l)}" title="${esc(l.train)} ${esc(nm(l.from))} → ${esc(nm(l.to))}"></i>`).join('')
    +(o.hotel?(()=>{const k=L.findIndex(l=>l.to==o.hotel.city);if(k<0||k+1>=L.length)return'';const a=L[k].t1,b=L[k+1].t0;return `<i class="h" style="left:${(a-T0)/span*100}%;width:${(b-a)/span*100}%" title="Hotellnatt i ${esc(nm(o.hotel.city))}"></i>`})():'');
  const ops=[...new Map(L.map(l=>[bolag(l.agency),l])).entries()].map(([b,l])=>`<span class="op" style="--dot:${col(l)}">${esc(b)}</span>`).join('');
  // resplan
  let tl='';
  L.forEach((l,i)=>{
    if(i==0)tl+=`<li class="st" style="--col:${col(l)}"><span class="t">${l.hm0}</span><span class="dot"></span><span class="n">${esc(nm(l.from))}${l.track0?`<small>spår ${esc(l.track0)}</small>`:''}</span></li>`;
    tl+=`<li class="ride" style="--col:${col(l)}"><span></span><span class="ln"></span><span class="info"><span class="tn">${esc(l.train||modeName(l))}</span>${esc(modeName(l))} · ${esc(l.agency)} · ${dur((l.t1-l.t0)/6e4)}</span></li>`;
    const nxt=L[i+1], d1=l.d1!=o.d0?`<small>${pretty(l.d1)}</small>`:'';
    tl+=`<li class="st" style="--col:${col(l)}"><span class="t">${l.hm1}${d1}</span><span class="dot"></span><span class="n">${esc(nm(l.to))}${l.track1?`<small>spår ${esc(l.track1)}</small>`:''}</span></li>`;
    if(nxt){const w=(nxt.t0-l.t1)/6e4, isHotel=o.hotel&&l.to==o.hotel.city;
      tl+=`<li class="xfer ${isHotel?'hotel':w<8?'tight':''}"><span></span><span class="ln"></span><span class="info">${isHotel?`⌂ Hotellnatt i ${esc(nm(o.hotel.city))} · vidare ${esc(o.hotel.out)}`:`${w<8?'⚠︎ Kort byte':'Byte'}${nm(nxt.from)!=nm(l.to)?` till ${esc(nm(nxt.from))}`:''} · ${dur(w)}`}</span></li>`;
      tl+=`<li class="st" style="--col:${col(nxt)}"><span class="t">${nxt.hm0}${nxt.d0!=l.d1?`<small>${pretty(nxt.d0)}</small>`:''}</span><span class="dot"></span><span class="n">${esc(nm(nxt.from))}${nxt.track0?`<small>spår ${esc(nxt.track0)}</small>`:''}</span></li>`}
  });
  const tails=o.tails.filter(t=>t.legs.length).length>1?`<div class="tails"><h4>Alternativ för sista biten</h4>${o.tails.filter(t=>t.legs.length).map(t=>`<div class="tail"><span>${t.legs.map(l=>`${l.hm0} ${esc(l.train||modeName(l))} till ${esc(nm(l.to))}`).join(' + ')}</span><b>framme ${esc(t.arr.slice(-5))}</b></div>`).join('')}</div>`:'';
  const [ic,kn]=KIND[o.kind]||['',o.kind];
  return `<article class="card" data-i="${idx}"><div class="sum" role="button" tabindex="0" aria-expanded="false">
    <div class="top"><div><div class="times">${o.hm0}<span class="arrow">→</span>${o.hm1}${dd>0?`<sup>+${dd}</sup>`:''}</div>
      <div class="meta"><b>${dur((o.t1-o.t0)/6e4)}</b> · ${o.changes==0?'direkt':o.changes==1?'1 byte':o.changes+' byten'} · ${pretty(o.d0)}</div></div>
      <span class="badge ${esc(o.kind)}">${ic} ${esc(kn)}</span></div>
    <div><div class="track">${segs}</div><div class="ends" style="margin-top:6px"><span>${esc(nm(L[0].from))}</span><span>${esc(nm(L[L.length-1].to))}</span></div></div>
    <div class="top" style="align-items:center"><div class="ops">${ops}</div><span class="more">Resplan <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="m6 9 6 6 6-6"/></svg></span></div>
    ${o.flags.map(f=>`<div class="flag">⚠︎ ${esc(f)}</div>`).join('')}
  </div><div class="det"><ol class="tl">${tl}</ol>${tails}${prisLankar(L)}</div></article>`;
}
const SORT={arr:['Framme först',(a,b)=>a.t1-b.t1],dep:['Avgång',(a,b)=>a.t0-b.t0],dur:['Kortast',(a,b)=>(a.t1-a.t0)-(b.t1-b.t0)],chg:['Färst byten',(a,b)=>a.changes-b.changes||a.t1-b.t1]};
function render(){
  const d=last, out=$('#out');
  if(!d.options.length){out.innerHTML=`<div class="msg"><b>Inga förslag det här dygnet</b>Prova en annan dag eller en tidigare avgångstid.</div>`;return}
  const opts=[...d.options].sort(SORT[sortBy][1]);
  out.innerHTML=`<div class="bar-head"><h2>${esc(pick.fran.name)} → ${esc(pick.till.name)}<small>${d.options.length} förslag · ${pretty($('#datum').value)} efter ${$('#tid').value}</small></h2>
    <div class="seg">${Object.entries(SORT).map(([k,[t]])=>`<button type="button" data-s="${k}" class="${k==sortBy?'on':''}">${t}</button>`).join('')}</div></div>
    <div class="legend"><span style="--dot:var(--c-fast)">Fjärrtåg</span><span style="--dot:var(--c-reg)">Regionaltåg</span><span style="--dot:var(--c-night)">Nattåg</span><span style="--dot:var(--c-bus)">Buss</span><span style="--dot:var(--c-hotel)">Hotellnatt</span></div>`
    +opts.map(card).join('')
    +(d.rejected.length?`<details class="rej"><summary>${d.rejected.length} förslag bortsorterade</summary><ul>${d.rejected.map(r=>`<li>${esc(r)}</li>`).join('')}</ul></details>`:'');
}
$('#out').addEventListener('click',e=>{
  const s=e.target.closest('[data-s]'); if(s){sortBy=s.dataset.s;render();return}
  const sum=e.target.closest('.sum'); if(sum&&!e.target.closest('a')){const c=sum.parentElement;c.classList.toggle('open');sum.setAttribute('aria-expanded',c.classList.contains('open'))}});
$('#out').addEventListener('keydown',e=>{if((e.key=='Enter'||e.key==' ')&&e.target.classList.contains('sum')){e.preventDefault();e.target.click()}});
$('#f').onsubmit=async e=>{e.preventDefault();const out=$('#out');
  if(!pick.fran||!pick.till){out.innerHTML='<div class="msg"><b>Välj station i listan</b>Börja skriva i Från och Till och välj ett av förslagen.</div>';return}
  try{localStorage.setItem('senaste',JSON.stringify(pick))}catch(e){}
  $('#go').disabled=true;out.innerHTML='<div class="bar-head"><h2>Söker …<small>Hotellnätter och sista biten räknas fram, det kan ta en halv minut.</small></h2></div>'+'<div class="skel"></div>'.repeat(3);
  try{const q=new URLSearchParams({fran:pick.fran.id,till:pick.till.id,datum:$('#datum').value,tid:$('#tid').value});
    const r=await fetch('/api/sok?'+q), d=await r.json(); if(!r.ok)throw new Error(d.error);
    last=d; render(); const first=document.querySelector('.card'); if(first&&window.innerWidth>640)first.classList.add('open');
  }catch(err){out.innerHTML=`<div class="msg"><b>Något gick fel</b>${esc(err.message)}</div>`}
  $('#go').disabled=false};
</script></body></html>"""

if __name__ == "__main__":
    print(f"Söksidan: http://0.0.0.0:{PORT}/ ({'lösenordsskyddad' if PASSWORD else 'UTAN lösenord'})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF
  if [ ! -s $D/in/lander.json ]; then   # landsgränser (Natural Earth, fri) så att varje station visar rätt land
    curl -fsSL -o /tmp/ne.geojson https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson \
      && python3 $D/kod/sok.py --lander /tmp/ne.geojson $D/in/lander.json; rm -f /tmp/ne.geojson
  fi
  if [ ! -s $D/sok.losen ]; then   # skapas en gång; läs med: cat /opt/tagplan/sok.losen
    (umask 077; head -c 18 /dev/urandom | base64 | tr -d '/+=' > $D/sok.losen); echo "nytt lösenord för söksidan i $D/sok.losen"
  fi
  cat > /etc/systemd/system/tagplan-sok.service <<EOF
[Unit]
Description=Tagplaneraren - soksida
After=tagplan.service
[Service]
ExecStart=/usr/bin/python3 $D/kod/sok.py $D/in 8110 $D/sok.losen
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable -q tagplan-sok; systemctl restart tagplan-sok
  if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 8110/tcp; fi
}

fetch() {  # fetch <namn> <url>  – behåller gårdagens fil om nedladdningen misslyckas
  if curl -fsSL --retry 3 -A "tagplaneraren (olle@nordwikpartners.se)" -o $D/in/$1.tmp "$2" && unzip -tq $D/in/$1.tmp >/dev/null; then
    mv $D/in/$1.tmp $D/in/$1.zip; echo "hämtad: $1"
  else rm -f $D/in/$1.tmp; echo "MISSLYCKADES: $1 (använder förra versionen)"; fi
}

build() {
  write_filter
  fetch de-full https://download.gtfs.de/germany/free/latest.zip
  fetch dk https://www.rejseplanen.info/labs/GTFS.zip
  fetch it https://proxy.busone.app/trenitalia/gtfs.zip
  fetch sta https://proxy.busone.app/sta/gtfs.zip
  # Österrike (ÖBB, CC BY 4.0) och Schweiz (opentransportdata.swiss): en fil per tidtabellsår, nytt år från 13 december
  Y=$(date +%Y); [ "$(date +%m%d)" -ge 1213 ] && Y=$((Y+1))
  fetch at-full "https://static.web.oebb.at/open-data/soll-fahrplan-gtfs/GTFS_Fahrplan_$Y.zip"
  fetch ch-full "https://data.opentransportdata.swiss/dataset/timetable-$Y-gtfs2020/permalink"
  if [ -s $D/trafiklab.key ]; then fetch se "https://api.resrobot.se/gtfs/sweden.zip?key=$(cat $D/trafiklab.key)"; else fetch se "$SE_URL"; fi
  [ $D/in/de-full.zip -nt $D/in/de.zip ] && python3 $D/kod/filt.py $D/in/de-full.zip $D/in/de.zip && echo "Tyskland filtrerad"
  for f in at ch; do [ $D/in/$f-full.zip -nt $D/in/$f.zip ] && nice python3 $D/kod/filt.py $D/in/$f-full.zip $D/in/$f.zip && echo "$f filtrerad"; done
  rm -rf $D/next && mkdir -p $D/next && cd $D/next
  for f in se dk de it sta at ch; do [ -s $D/in/$f.zip ] && ln -sf $D/in/$f.zip $f.zip; done
  $D/motis config *.zip >/dev/null
  sed -i 's/num_days: 365/num_days: 21/; s/with_shapes: true/with_shapes: false/; s/railviz: true/railviz: false/; s/merge_dupes_inter_src: false/merge_dupes_inter_src: true/; s/extend_missing_footpaths: false/extend_missing_footpaths: true/; s/link_stop_distance: 100/link_stop_distance: 300/' config.yml
  systemctl stop tagplan   # frigör minne under bygget
  if $D/motis import -d data >/dev/null 2>&1 && [ -s data/tt.bin ]; then
    set_port data
    rm -rf $D/old; [ -d $D/run ] && mv $D/run $D/old; mv $D/next $D/run; echo "nytt bygge klart"
  else echo "BYGGET MISSLYCKADES – kör vidare på förra"; fi
  systemctl start tagplan
  systemctl restart tagplan-sok 2>/dev/null || true   # läs om stationslistan
}

case "$MODE" in
  install) install_base; if [ -s $D/run/data/tt.bin ]; then set_port $D/run/data; systemctl restart tagplan; else build; fi; install_web ;;
  cron)    [ "$(date +%H)" = "03" ] && build ;;
  build)   build ;;
esac
echo "=== $(date -Is) klar; tjänsten: $(systemctl is-active tagplan)"
