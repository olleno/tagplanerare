# Tågplaneraren

Reseplanerare för tåg, regionaltåg och buss i Europa, dörr till dörr. Bygger på sökmotorn [MOTIS](https://github.com/motis-project/motis) och öppna tidtabeller.

- `server/tagplan.sh` – installerar och uppdaterar allt på servern (körs varje timme; bygger om tidtabellerna varje natt).
- `kod/planner_api.py` – sorterar bort dåliga förslag (aldrig natt på en station), bygger hotellnätter och visar alternativen för sista biten.

## Datakällor
- Tyskland: DELFI e.V. via gtfs.de (CC BY 4.0)
- Danmark: Rejseplanen (CC BY 4.0)
- Sverige: Trafiklab / Samtrafiken, GTFS Sverige 2 (CC0)
- Italien: Trenitalia och STA Südtirol via BusOne
