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
    def k(x):
        if rail(x[it]): keep_r.add(x[ir]);return True
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

def _leg(l):
    return {"from": l["from"]["name"], "to": l["to"]["name"], "dep": _hm(l["startTime"], l["from"].get("tz")),
            "arr": _hm(l["endTime"], l["to"].get("tz")), "train": l.get("displayName") or "",
            "agency": l.get("agencyName") or "", "url": l.get("agencyUrl") or "", "mode": l["mode"],
            "day": P._loc(l["startTime"], l["from"].get("tz")).strftime("%Y-%m-%d")}

def to_json(res):
    opts = []
    for g in res["options"]:
        L = g["legs"]; tz0, tz1 = L[0]["from"].get("tz"), L[-1]["to"].get("tz")
        s, e = P._loc(g["start"], tz0), P._loc(g["end"], tz1)
        tails = []
        for t in sorted(g["tails"], key=lambda t: P._t(t["end"])):
            if t["legs"]: tails.append({"legs": [_leg(l) for l in t["legs"]], "arr": _hm(t["end"], t["legs"][-1]["to"].get("tz"))})
        h = g["hotel"]
        opts.append({"kind": g["kind"], "dep": _dag(s), "arr": _dag(e),
                     "hours": round((e - s).total_seconds() / 3600, 1), "changes": len(L) - 1,
                     "legs": [_leg(l) for l in L[: g["last"] + 1]], "all": [_leg(l) for l in L], "tails": tails, "flags": g["flags"],
                     "hotel": h and {"city": h["city"], "out": _dag(h["out"])}})
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
<style>
:root{--bg:#f6f5f2;--card:#fff;--fg:#1d1d1b;--mut:#6b6a66;--line:#e2e0da;--acc:#1f5f8b;--warn:#a5520f;--hot:#6b3fa0}
@media (prefers-color-scheme:dark){:root{--bg:#161616;--card:#202020;--fg:#ecebe8;--mut:#9a9893;--line:#333;--acc:#6fb0e0;--warn:#e0a060;--hot:#b896e0}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px 60px}h1{font-size:22px;margin:0 0 16px}
form{display:grid;grid-template-columns:1fr 1fr;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
label{display:flex;flex-direction:column;font-size:12px;color:var(--mut);gap:4px;position:relative}
input,button{font:inherit;padding:9px 10px;border:1px solid var(--line);border-radius:7px;background:var(--bg);color:var(--fg)}
button{grid-column:1/-1;background:var(--acc);color:#fff;border:0;font-weight:600;cursor:pointer}button:disabled{opacity:.6}
.sw{grid-column:1/-1;justify-self:start;background:none;color:var(--acc);padding:0;font-weight:400;font-size:13px}
.sug{position:absolute;top:100%;left:0;right:0;z-index:5;background:var(--card);border:1px solid var(--line);border-radius:7px;margin-top:2px;max-height:300px;overflow:auto;display:none}
.sug div{padding:7px 10px;cursor:pointer;color:var(--fg);font-size:14px}.sug div small{color:var(--mut);margin-left:6px}
.sug div:hover,.sug div.on{background:var(--bg)}
.opt{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-top:12px}
.head{display:flex;flex-wrap:wrap;gap:8px 14px;align-items:baseline}.kind{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;padding:2px 7px;border-radius:4px;background:var(--bg);color:var(--acc)}
.kind.hotell{color:var(--hot)}.time{font-size:17px;font-weight:600}.meta{color:var(--mut);font-size:13px}
table{width:100%;border-collapse:collapse;margin-top:8px;font-size:13.5px}td{padding:3px 6px 3px 0;vertical-align:top}td.t{white-space:nowrap;font-variant-numeric:tabular-nums}td.tr{color:var(--mut)}
.hotel{color:var(--hot);font-weight:600;margin:4px 0}.tail{font-size:13px;margin-top:6px;color:var(--mut)}.flag{color:var(--warn);font-size:13px;margin-top:4px}
.price{margin-top:8px;font-size:13px;display:flex;flex-wrap:wrap;gap:6px;align-items:center}.price a{color:var(--acc);border:1px solid var(--line);border-radius:6px;padding:3px 8px;text-decoration:none}.price a:hover{background:var(--bg)}
.msg{margin-top:16px;color:var(--mut)}.rej{margin-top:18px;font-size:13px;color:var(--mut)}
@media (max-width:560px){form{grid-template-columns:1fr}td.tr{display:none}}
</style></head><body><main>
<h1>Tågplaneraren</h1>
<form id="f">
  <label>Från<input id="fran" autocomplete="off" placeholder="t.ex. Stockholm C" required><div class="sug"></div></label>
  <label>Till<input id="till" autocomplete="off" placeholder="t.ex. Bolzano" required><div class="sug"></div></label>
  <label>Datum<input id="datum" type="date" required></label>
  <label>Tid (svensk tid)<input id="tid" type="time" value="08:00" required></label>
  <button type="button" class="sw" id="sw">⇅ byt håll</button>
  <button id="go">Sök resa</button>
</form>
<div id="out"></div>
</main><script>
const $=s=>document.querySelector(s), esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const pick={fran:null,till:null};
$('#datum').value=new Date(Date.now()+864e5).toISOString().slice(0,10);
try{const p=JSON.parse(localStorage.getItem('senaste')||'null');if(p){for(const k of['fran','till']){pick[k]=p[k];$('#'+k).value=p[k].name}}}catch(e){}
for(const k of['fran','till']){
  const inp=$('#'+k), box=inp.nextElementSibling; let items=[], on=-1, timer;
  const show=()=>{box.innerHTML=items.map((s,i)=>`<div class="${i==on?'on':''}" data-i="${i}">${esc(s.name)}<small>${esc(s.land)}</small></div>`).join('');box.style.display=items.length?'block':'none'};
  const choose=i=>{pick[k]=items[i];inp.value=items[i].name;items=[];show()};
  inp.addEventListener('input',()=>{pick[k]=null;clearTimeout(timer);timer=setTimeout(async()=>{
    items=await (await fetch('/api/stationer?q='+encodeURIComponent(inp.value))).json();on=items.length?0:-1;show()},150)});
  inp.addEventListener('keydown',e=>{if(!items.length)return;
    if(e.key=='ArrowDown'){on=(on+1)%items.length;show();e.preventDefault()}
    else if(e.key=='ArrowUp'){on=(on-1+items.length)%items.length;show();e.preventDefault()}
    else if(e.key=='Enter'){choose(Math.max(on,0));e.preventDefault()}
    else if(e.key=='Escape'){items=[];show()}});
  box.addEventListener('mousedown',e=>{const d=e.target.closest('[data-i]');if(d){choose(+d.dataset.i);e.preventDefault()}});
  inp.addEventListener('blur',()=>setTimeout(()=>{if(items.length&&!pick[k])choose(0);items=[];show()},100));
}
$('#sw').onclick=()=>{[pick.fran,pick.till]=[pick.till,pick.fran];[$('#fran').value,$('#till').value]=[$('#till').value,$('#fran').value]};
// Priser: SJ säljer biljetter för de här bolagen och visar dagens pris direkt i länken. Övriga bolag: deras egen sida.
const SJ_SALJER=/^(SJ|Öresundståg|Skånetrafiken|Norrtåg|Mälartåg|Västtågen|Krösatågen|Tåg i Bergslagen)\b/i;
const sjNamn=n=>n.replace(/\s+Centralstation$/,' Central').replace(/\s+C$/,' Central').replace(/^København H$/,'Köpenhamn H');
function prisLankar(legs){
  const out=[]; let i=0;
  while(i<legs.length){
    if(SJ_SALJER.test(legs[i].agency)){let j=i;while(j+1<legs.length&&SJ_SALJER.test(legs[j+1].agency))j++;
      out.push({t:`${legs[i].from} → ${legs[j].to} hos SJ`,u:`https://www.sj.se/sok-resa/valj-resa/${encodeURIComponent(sjNamn(legs[i].from))}/${encodeURIComponent(sjNamn(legs[j].to))}/${legs[i].day}`});i=j+1}
    else{if(legs[i].url&&!out.some(o=>o.u==legs[i].url))out.push({t:`${legs[i].agency}`,u:legs[i].url});i++}
  }
  return out.length?`<div class="price">Priser: ${out.map(o=>`<a href="${esc(o.u)}" target="_blank" rel="noopener">${esc(o.t)}</a>`).join('')}</div>`:'';
}
const legRow=l=>`<tr><td class="t">${esc(l.dep)}</td><td>${esc(l.from)} → ${esc(l.to)}</td><td class="t">${esc(l.arr)}</td><td class="tr">${esc(l.train)} ${esc(l.agency)}</td></tr>`;
$('#f').onsubmit=async e=>{e.preventDefault();const out=$('#out');
  if(!pick.fran||!pick.till){out.innerHTML='<p class="msg">Välj station i listan för både Från och Till.</p>';return}
  try{localStorage.setItem('senaste',JSON.stringify(pick))}catch(e){}
  $('#go').disabled=true;out.innerHTML='<p class="msg">Söker … (kan ta en halv minut när hotellnätter räknas fram)</p>';
  try{const q=new URLSearchParams({fran:pick.fran.id,till:pick.till.id,datum:$('#datum').value,tid:$('#tid').value});
    const r=await fetch('/api/sok?'+q), d=await r.json(); if(!r.ok)throw new Error(d.error);
    out.innerHTML=(d.options.length?'':'<p class="msg">Inga förslag hittades för det dygnet.</p>')+d.options.map(o=>{
      let rows=o.legs.map(legRow).join('');
      if(o.hotel)rows=o.legs.map(l=>legRow(l)+(l.to==o.hotel.city?`<tr><td colspan="4" class="hotel">🛏 Hotellnatt i ${esc(o.hotel.city)} – vidare ${esc(o.hotel.out)}</td></tr>`:'')).join('');
      return `<div class="opt"><div class="head"><span class="kind ${o.kind}">${esc(o.kind)}</span><span class="time">${esc(o.dep)} → ${esc(o.arr)}</span>
        <span class="meta">${o.hours} h · ${o.changes} byten</span></div><table>${rows}</table>
        ${o.tails.map(t=>`<div class="tail">Sista biten: ${t.legs.map(l=>`${esc(l.dep.slice(-5))} ${esc(l.mode=='BUS'?'buss':l.mode=='REGIONAL_RAIL'?'regionaltåg':l.mode.toLowerCase())} ${esc(l.train)} till ${esc(l.to)}`).join(' + ')} → framme ${esc(t.arr.slice(-5))}</div>`).join('')}
        ${o.flags.map(f=>`<div class="flag">OBS: ${esc(f)}</div>`).join('')}${prisLankar(o.all)}</div>`}).join('')
      +(d.rejected.length?`<p class="rej">Bortsorterat: ${d.rejected.map(esc).join('; ')}</p>`:'');
  }catch(err){out.innerHTML=`<p class="msg">Något gick fel: ${esc(err.message)}</p>`}
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
