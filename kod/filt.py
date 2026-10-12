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
