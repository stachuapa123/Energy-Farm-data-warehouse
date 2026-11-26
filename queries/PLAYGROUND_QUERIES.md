# Cube Playground – the 10 queries

The queries assume the T2 data (2024–2025):
* **current month** = the last full month of data = **December 2025**
* **last quarter** = the last full quarter = **Q4 2025**

All times are UTC. Every member belongs to the cube **Energy Production**
(`EnergyProduction`).

## Running a query

Open http://localhost:4000 → **Build**. Then either:
* paste the JSON file with Playground's *paste JSON query* option, or
* build the query with the settings in the table below.

Click **Run**, and keep a screenshot of the result and of the **SQL** tab for
the presentation.

| # | Requirement | Measures | Dimensions | Filters | Reading Date | Order / limit |
|---|---|---|---|---|---|---|
| 1 | Current month vs previous month | totalEnergy, previousMonthEnergy, energyChangeVsPreviousMonth | – | – | 2025-11-01 … 2025-12-31, **month** | readingDate asc |
| 2 | Top 5 units, current month | totalEnergy, capacityFactor | unitId, unitType | – | 2025-12-01 … 2025-12-31 | totalEnergy desc, limit 5 |
| 3 | Solar: Sunny vs Cloudy days | avgDailyEnergyPerUnit, unitDays | skyConditionOfDay | unitType = Solar; skyConditionOfDay = Sunny, Cloudy | – | – |
| 4 | Wind: daily wind speed ranges | avgDailyEnergyPerUnit, avgWindSpeed, unitDays | dailyWindSpeedCategory | unitType = Wind | – | avgWindSpeed asc |
| 5 | Zones, last quarter | totalEnergy | zoneName | – | 2025-10-01 … 2025-12-31 | totalEnergy desc |
| 6 | Over 5 years vs under 1 year | totalEnergy, avgHourlyEnergy, capacityFactor | olderUnit, ageCategory | ageCategory = under 1 year, 5-10 years, over 10 years | – | – |
| 7 | Older units, temperature ≥ 30 °C | avgHourlyEnergy, readingsCount | unitType | olderUnit = Yes; temperatureCategory = hot | – | – |
| 8 | Decline with age per unit type | capacityFactor, unitsCount | unitType, ageCategory | – | – | unitType, ageCategory |
| 9 | Lowest units on optimal weather days | capacityFactor, avgDailyEnergyPerUnit, unitDays | unitType, unitId, modelName, manufacturerName | optimalWeatherDay = Yes | – | unitType asc, capacityFactor asc |
| 10 | Oldest wind turbine vs same month last year | totalEnergy, sameMonthLastYearEnergy, energyChangeVsSameMonthLastYear | unitId | oldestWindTurbine = Yes | 2025-12-01 … 2025-12-31, **month** | – |

## Notes

* **Q1 and Q10** use multi-stage `time_shift` measures, the same technique as
  the template's `previousMonthProfit`. They need Reading Date with
  granularity **month**. Multi-stage time shifts require Cube's Tesseract
  engine (enabled by default from Cube v1.7.0).
* `sql_crosscheck.sql` computes the same 10 queries in SQL on `FlatTablePhysical`, to
  check the Playground results.
* **Q9** can list a unit twice, once per SCD2 version. For example, the
  Siemens turbines (WT-GDA-02, WT-SZC-03, WT-BYD-03) appear with their old
  (Siemens Gamesa, 2024) and new (Siemens Energy, 2025) manufacturer name.
  This is expected.
* **Q8** compares capacity factor, not total energy, because the units' sizes
  range from 500 kW to 4,200 kW.
* **Switching the source:**
  * the cube reads the view `dbo.FlatTable`; set `sql_table: dbo.FlatTablePhysical`
    in `cube/schema/energy_production.cube.yml` to use the physical flat table;
  * set `CUBEJS_DB_NAME=EcoVoltDW_Part` in `docker-compose.yml` (repository
    root) for the partitioned variant, then run `docker compose up -d cube`.
