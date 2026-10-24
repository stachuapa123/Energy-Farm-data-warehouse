# EcoVolt data generator

Generates both data sources of the *Energy Production Monitoring* process in two snapshots (T1, T2):

| Source | Type | Files |
|---|---|---|
| PowerMaster | relational DB (MS SQL Server), bulk-load CSV | `Manufacturer`, `Model`, `Zone`, `Unit`, `ProductionLog` |
| Weather_Data | CSV file from the meteorological institute | `Weather_Data.csv` |

Requirements: Python 3.9+, `numpy`, `pandas`, `scipy`.

```
python generator.py                          # default: ~500k ProductionLog rows in T2
python generator.py --target-rows 1000000    # ~1M rows (scales the number of units)
python generator.py --start 2025-01-01 --t1-end 2026-07-01 --t2-end 2026-10-01 --seed 2026 --out Data
python validate.py Data                      # integrity + realism report
```

Runs in about 5 s. The same seed always gives the same data.

## Default output

| | T1 (data before 2026-07-01) | T2 (data before 2026-10-01) |
|---|---|---|
| ProductionLog (fact rows) | 419,592 | 500,208 |
| Weather_Data rows | 104,832 | 122,496 |
| Unit | 35 | 38 |
| Model | 15 | 16 |
| Manufacturer / Zone | 8 / 8 | 8 / 8 |

```
Data/
  T1/PowerMaster/*.csv, T1/Weather/Weather_Data.csv      full snapshot T1
  T2/PowerMaster/*.csv, T2/Weather/Weather_Data.csv      full snapshot T2
  T2_delta/PowerMaster/Model_new.csv, Unit_new.csv, ProductionLog_new.csv, apply_T2_delta.sql
  T2_delta/Weather/Weather_Data_new.csv                  rows added to the CSV after T1
  load_snapshot.sql      BULK INSERT of a full snapshot
  manifest.json          parameters, row counts, list of T2 changes
  validation_report.txt  output of validate.py
```

## T1 → T2

T2 = T1 + new facts + new and changed dimension rows. The first 419,592 ProductionLog rows of T2 are identical to T1 (same IDs).

* **New fact rows**: 80,616 hourly readings (Jul–Sep 2026) and 17,664 weather rows.
* **New dimension rows**: model *Hi-MO 9 Array 1500kWp*; units `WT-GDA-04`, `PV-GDA-03`, `PV-POZ-04` (farm expansion).
* **Changed dimension rows** (UPDATEs in the source system, SCD material for the warehouse):
  * Manufacturer 2: `Siemens Gamesa, Spain` → `Siemens Energy, Germany` (rebranding).
  * Unit `PV-WAW-01` repowered: panels replaced, `ModelID` 11 → 16 and `InstallationDate` 2016-08-08 → 2026-08-09; logged as `Maintenance` during the 3-day works, higher output afterwards.
  * Zones Gdańsk and Poznań: `AreaSizeSqm` enlarged for the new units.

Two ways to get T2 into SQL Server:
1. Load the full `T2` snapshot into an empty database, or
2. Load `T1`, then run `T2_delta/PowerMaster/apply_T2_delta.sql` (new dimension rows → UPDATEs → new facts).

## Loading (BULK INSERT)

1. Copy `Data` to the SQL Server machine (BULK INSERT paths are resolved on the server), e.g. `C:\EcoVolt\Data`.
2. Run `Schemas/PowerMaster_schema.sql`.
3. In `load_snapshot.sql` set `@dir` to `...\T1\PowerMaster\` (or `T2`) and run it.
4. Optional: `apply_T2_delta.sql` with its `@dir` set to `...\T2_delta\PowerMaster\`.

File format: UTF-8 (`CODEPAGE = '65001'`, SQL Server 2016+), comma separated, LF line ends, header row, dates `yyyy-MM-dd HH:mm:ss`. `KEEPIDENTITY` keeps the generated IDs so keys are identical in both snapshots and in the CSV. The Weather CSV uses ISO 8601 `yyyy-MM-ddTHH:mm:ss` as in the specification.

## Integration (business keys)

* `Weather_Data.ZoneID` = `Zone.ZoneID` = `Unit.ZoneID`.
* `Weather_Data.Datetime` = `ProductionLog.LogDate`: both mark the start of the hour, in UTC (no DST gaps or duplicates). Every reading has exactly one weather row.
* `UnitID` (`WT-GDA-01`, `PV-POZ-03`, …) is the same key that the ServiceDesk maintenance system uses.

## Zones

Capitals of the 8 northern voivodeships: 1 Gdańsk, 2 Szczecin, 3 Olsztyn, 4 Białystok, 5 Bydgoszcz, 6 Zielona Góra, 7 Poznań, 8 Warszawa. Each has its real coordinates (sun position) and its own climate: windier and milder on the coast, colder winters in the east, hotter summers in the west.

## How the data is made realistic

**Weather (hourly, per zone)**
* Annual and daily temperature cycles. The daily range is smaller under clouds and on the coast.
* Synoptic weather systems lasting several days, shared between zones with an east–west gradient. Highs bring clear skies, weak wind, warm summers and cold winters.
* Heat waves (hours above 30 °C occur, mostly in the west) and winter cold spells.
* Wind follows a Weibull distribution, is stronger in winter and in the afternoon, and is strongest on the coast. Daily means above 30 km/h occur on several days per zone.
* Cloud cover in oktas, U-shaped (often 0–1 or 7–8) and cloudier in winter. Precipitation depends on clouds and season, about 550–650 mm per year.
* Sunshine minutes come from real sun elevation and cloud cover, about 1,350–1,700 h per year.

**Wind turbines**
* Station wind is scaled to hub height (model hub height, zone roughness) and adjusted for site and turbulence noise and air density.
* Production follows each model's power curve (cut-in, rated speed, storm cut-out at 25 m/s). Blade icing occurs in freezing precipitation.
* Capacity factor is about 27 % (Polish onshore: 25–30 %). Daily Pearson r between station wind and turbine energy is about 0.9.

**PV arrays** (a "Solar unit" is an array block, e.g. 1000 kWp)
* Clear-sky irradiance from sun position is reduced by clouds and boosted by panel tilt.
* Losses from cell temperature (model temperature coefficient), snow cover, and soiling that rain washes off.
* Yield is about 11 % capacity factor (≈ 950 kWh/kWp). Sunny days give about 4× the energy of cloudy days. Output is 0 at night.

**Aging and reliability**
* Yearly degradation per model: wind 1.0–1.6 %, PV 0.35–0.7 %, so wind declines faster.
* Fault rate rises with age, and again past the model's expected lifespan. Each unit has its own reliability, so some units are problematic.
* Turbine faults are more likely in storms and icing, PV faults in heat and thunderstorms. Repair times are lognormal, with occasional major failures lasting weeks.
* Planned maintenance: turbines twice a year on the calmest day of the window, PV once a year in spring.
* Hours with `Fault` or `Maintenance` have `EnergyProduced = 0`. Availability is about 97 % for wind and 99.6 % for PV.
* Units installed during the logged period start reporting from their installation day.

Calendar-year statistics are printed by `validate.py` (see `validation_report.txt`).
