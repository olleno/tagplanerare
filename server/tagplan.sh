#!/bin/bash
# Tågplaneraren på Olles Hetzner-server. Körs som root.
# Första gången: installerar allt. Därefter körs den varje timme av cron och gör:
#  - hämtar senaste versionen av sig själv från Dropbox och kör om den om den ändrats
#  - varje natt 03:xx: laddar ner färska tidtabeller, bygger om och startar om sökmotorn
set -u
SELF_URL="https://raw.githubusercontent.com/olleno/tagplanerare/main/server/tagplan.sh"
SE_URL="https://raw.githubusercontent.com/olleno/tagplanerare/main/data/sverige-gtfs.zip"
D=/opt/tagplan
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
  if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 8080/tcp; fi
}

write_filter() {
cat > $D/kod/filt.py <<'PY'
import zipfile,csv,io,sys
csv.field_size_limit(10**9)
src,dst=sys.argv[1],sys.argv[2]
z=zipfile.ZipFile(src)
def rd(n): return csv.reader(io.TextIOWrapper(z.open(n),'utf-8-sig',newline=''))
rail=lambda t: t in('1','2') or (t.isdigit() and (100<=int(t)<=117 or 400<=int(t)<=405))
out=zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED)
def w(n,rows):
    b=io.StringIO();csv.writer(b,lineterminator='\n').writerows(rows);out.writestr(n,b.getvalue())
r=rd('routes.txt');h=next(r);it=h.index('route_type');ir=h.index('route_id')
routes=[h]+[x for x in r if rail(x[it])];keep_r={x[ir] for x in routes[1:]};w('routes.txt',routes)
r=rd('trips.txt');h=next(r);ir=h.index('route_id');itr=h.index('trip_id');isv=h.index('service_id')
trips=[h]+[x for x in r if x[ir] in keep_r];keep_t={x[itr] for x in trips[1:]};keep_s={x[isv] for x in trips[1:]}
w('trips.txt',trips)
stops=set()
with out.open('stop_times.txt','w',force_zip64=True) as f:
    t=io.TextIOWrapper(f,'utf-8',newline='');cw=csv.writer(t,lineterminator='\n')
    r=rd('stop_times.txt');h=next(r);cw.writerow(h);a=h.index('trip_id');s=h.index('stop_id')
    for x in r:
        if x[a] in keep_t: cw.writerow(x);stops.add(x[s])
    t.flush();t.detach()
r=rd('stops.txt');h=next(r);i=h.index('stop_id');p=h.index('parent_station') if 'parent_station' in h else None
rows=list(r);par={x[p] for x in rows if p is not None and x[i] in stops and x[p]}
w('stops.txt',[h]+[x for x in rows if x[i] in stops or x[i] in par])
for n in ('calendar.txt','calendar_dates.txt'):
    if n in z.namelist():
        r=rd(n);h=next(r);k=h.index('service_id');w(n,[h]+[x for x in r if x[k] in keep_s])
for n in ('agency.txt','feed_info.txt','attributions.txt'):
    if n in z.namelist(): out.writestr(n,z.read(n))
out.close()
PY
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
  if [ -s $D/trafiklab.key ]; then fetch se "https://api.resrobot.se/gtfs/sweden.zip?key=$(cat $D/trafiklab.key)"; else fetch se "$SE_URL"; fi
  [ $D/in/de-full.zip -nt $D/in/de.zip ] && python3 $D/kod/filt.py $D/in/de-full.zip $D/in/de.zip && echo "Tyskland filtrerad"
  rm -rf $D/next && mkdir -p $D/next && cd $D/next
  for f in se dk de it sta; do ln -sf $D/in/$f.zip $f.zip; done
  $D/motis config se.zip dk.zip de.zip it.zip sta.zip >/dev/null
  sed -i 's/num_days: 365/num_days: 21/; s/with_shapes: true/with_shapes: false/; s/railviz: true/railviz: false/; s/merge_dupes_inter_src: false/merge_dupes_inter_src: true/; s/extend_missing_footpaths: false/extend_missing_footpaths: true/; s/link_stop_distance: 100/link_stop_distance: 300/' config.yml
  systemctl stop tagplan   # frigör minne under bygget
  if $D/motis import -d data >/dev/null 2>&1 && [ -s data/tt.bin ]; then
    rm -rf $D/old; [ -d $D/run ] && mv $D/run $D/old; mv $D/next $D/run; echo "nytt bygge klart"
  else echo "BYGGET MISSLYCKADES – kör vidare på förra"; fi
  systemctl start tagplan
}

case "$MODE" in
  install) install_base; [ -s $D/run/data/tt.bin ] || build ;;
  cron)    [ "$(date +%H)" = "03" ] && build ;;
  build)   build ;;
esac
echo "=== $(date -Is) klar; tjänsten: $(systemctl is-active tagplan)"
