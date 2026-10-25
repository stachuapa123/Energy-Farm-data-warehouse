# Weather_Data — CSV source (local meteorological institute)

Flat file delivered by the meteorological institute: **one row per hour per zone**.

| Property | Value |
|---|---|
| File name | `Weather_Data.csv` |
| Encoding | UTF-8 (ASCII content only), no BOM |
| Field separator | comma `,` |
| Decimal separator | dot `.` |
| Row terminator | LF (`\n`) |
| Header | column names in row 1 |
| Text qualifier | none (no field contains a comma) |
| Time zone | UTC |
| Granularity | 1 hour; the values describe the hour **starting** at `Datetime` |
| Missing values | none |

## Columns

| Col | Name | Type | Unit / format | Range | Description |
|---|---|---|---|---|---|
| A | `Datetime` | datetime | ISO 8601 `yyyy-MM-ddTHH:mm:ss` | full hours | Start of the measured hour (UTC) |
| B | `ZoneID` | integer | – | 1–8 | Zone of the farm; equals `Zone.ZoneID` in PowerMaster |
| C | `AvgTemperature` | decimal(4,1) | °C | approx. −25 … 36 | Mean air temperature in the hour |
| D | `AvgWindSpeed` | decimal(4,1) | m/s, measured at 10 m | 0 … ~25 | Mean wind speed in the hour |
| E | `Precipitation` | decimal(5,1) | mm | ≥ 0 | Precipitation total in the hour |
| F | `CloudCover` | integer | oktas | 0–8 | Cloud cover (0 = clear sky, 8 = overcast) |
| G | `SunshineDuration` | integer | minutes | 0–60 | Minutes of sunshine within the hour |

Key: (`Datetime`, `ZoneID`) is unique.

## Integration with PowerMaster

* `Weather_Data.ZoneID` = `Zone.ZoneID` (business key of the zone; the zone of a unit comes from `Unit.ZoneID`).
* `Weather_Data.Datetime` = `ProductionLog.LogDate` (both are hour starts in UTC), so every production reading has exactly one matching weather row:

```sql
ProductionLog pl
JOIN Unit u          ON u.UnitID = pl.UnitID
JOIN Weather w       ON w.ZoneID = u.ZoneID AND w.[Datetime] = pl.LogDate
```

* Daily analysis: aggregate both sides to `CAST(... AS DATE)` and the zone.

## Zones (ZoneID → ZoneName)

| ZoneID | ZoneName | Voivodeship |
|---|---|---|
| 1 | Gdansk | pomorskie |
| 2 | Szczecin | zachodniopomorskie |
| 3 | Olsztyn | warminsko-mazurskie |
| 4 | Bialystok | podlaskie |
| 5 | Bydgoszcz | kujawsko-pomorskie |
| 6 | Zielona Gora | lubuskie |
| 7 | Poznan | wielkopolskie |
| 8 | Warszawa | mazowieckie |

## Sample

```
Datetime,ZoneID,AvgTemperature,AvgWindSpeed,Precipitation,CloudCover,SunshineDuration
2025-07-15T11:00:00,7,27.4,3.9,0.0,1,58
2025-07-15T11:00:00,8,25.9,4.4,0.0,3,47
```

`Weather_Data_staging.sql` contains an optional staging table with matching types, for loading the file into SQL Server during ETL.
