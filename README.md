# Tågplaneraren

Reseplanerare för tåg, regionaltåg och buss i Europa, dörr till dörr. Bygger på sökmotorn [MOTIS](https://github.com/motis-project/motis) och öppna tidtabeller.

- `server/tagplan.sh` – installerar och uppdaterar allt på servern (körs varje timme; bygger om tidtabellerna varje natt).
- `kod/sok.py` – söksidan (port 8110, lösenordsskyddad): välj två valfria stationer, datum och tid.
- `kod/planner_api.py` – sorterar bort dåliga förslag (aldrig natt på en station), bygger hotellnätter och visar alternativen för sista biten.

## Datakällor
- Tyskland: DELFI e.V. via gtfs.de (CC BY 4.0)
- Danmark: Rejseplanen (CC BY 4.0)
- Sverige: Trafiklab / Samtrafiken, GTFS Sverige 2 (CC0)
- Italien: Trenitalia och STA Südtirol via BusOne
- Österrike: ÖBB Open Data, GTFS Soll-Fahrplan (CC BY 4.0)
- Schweiz: opentransportdata.swiss, Fahrplan GTFS
- Frankrike: SNCF Voyageurs, TGV/Intercités/TER (ODbL)
- Nederländerna: OVapi (gtfs.ovapi.nl)
- Landsgränser: Natural Earth (public domain)
