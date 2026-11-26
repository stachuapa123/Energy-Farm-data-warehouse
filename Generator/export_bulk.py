#!/usr/bin/env python3
"""Builds the sample data of the EcoVolt warehouse (bulk/*.csv) from the generator output.

The bulk files have the shape of the warehouse tables (one CSV per table, business keys instead of
surrogate keys), like bulk/ of the course template. 03_bulk_load.sql only stages and inserts them.
The ETL mapping of the relational design is applied here:
  * Date, Time, Status, Weather are generated (Weather: 1200 category combinations + "unknown");
  * Zone and Unit are SCD2: snapshot T1 gives the first versions, the differences in T2 give new versions
    valid from the first day after the T1 readings (or from the new installation date of replaced equipment);
  * every reading gets the weather of its zone and hour (raw values and categories) and
    MaxPossibleEnergy = MaxPowerCapacity of the unit version valid at the reading x 1 h.

Usage (from the repository root):
    python Generator/export_bulk.py                       # Data/ -> bulk/
    python Generator/export_bulk.py --data Data --out bulk
Requirements: Python 3.9+, pandas.
"""
import argparse
import os
from decimal import Decimal

import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPEN_END = "9999-12-31 00:00:00"
OPEN_START = "1900-01-01 00:00:00"

TEMPERATURE = ["freezing", "cold", "moderate", "warm", "hot"]
WIND = ["calm", "light", "moderate", "strong"]
PRECIPITATION = ["none", "light", "moderate", "heavy"]
CLOUD = ["clear", "partly cloudy", "overcast"]
SUNSHINE = ["none", "low", "medium", "high", "full"]
UNIT_ATTRIBUTES = ["ManufacturerID", "ManufacturerName", "ManufacturerCountry", "ModelID", "ModelName",
                   "UnitType", "MaxPowerCapacity", "InstallationDateTime", "ExpectedLifespanYears"]


def read(data, snapshot, path):
    return pd.read_csv(os.path.join(data, snapshot, path), dtype=str, keep_default_na=False)


def write(df, out, name):
    df.to_csv(os.path.join(out, name), index=False, lineterminator="\n")
    print(f"{name:<30} {len(df):>8} rows")


# ---------------------------------------------------------------- categories (half-open intervals)
def temperature_category(t):
    t = Decimal(t)
    return "freezing" if t < 0 else "cold" if t < 10 else "moderate" if t < 20 else "warm" if t < 30 else "hot"


def wind_category(v):
    v = Decimal(v)
    return "calm" if v < 3 else "light" if v < 6 else "moderate" if v < 9 else "strong"


def precipitation_category(p):
    p = Decimal(p)
    return "none" if p == 0 else "light" if p < Decimal("2.5") else "moderate" if p <= Decimal("7.6") else "heavy"


def cloud_category(c):
    c = int(c)
    return "clear" if c <= 2 else "partly cloudy" if c <= 5 else "overcast"


def sunshine_category(s):
    s = int(s)
    return "none" if s == 0 else "low" if s <= 20 else "medium" if s <= 40 else "high" if s < 60 else "full"


# ---------------------------------------------------------------- dimensions generated before the ETL
def date_dimension(first_day, last_day):
    days = pd.date_range(first_day, last_day, freq="D")
    month_day = days.month * 100 + days.day
    season = pd.Series("Winter", index=days)
    season[(month_day >= 321) & (month_day <= 620)] = "Spring"
    season[(month_day >= 621) & (month_day <= 922)] = "Summer"
    season[(month_day >= 923) & (month_day <= 1220)] = "Autumn"
    return pd.DataFrame({
        "Date": days.strftime("%Y-%m-%d"),
        "Year": days.year,
        "QuarterNo": days.quarter,
        "Month": days.month_name(),
        "MonthNo": days.month,
        "DayOfWeek": days.day_name(),
        "DayOfWeekNo": days.day_of_week + 1,
        "Season": season.values,
    })


def time_dimension():
    hours = range(24)
    return pd.DataFrame({
        "Hour": hours,
        "TimeOfDay": ["night" if h <= 5 else "morning" if h <= 11 else "afternoon" if h <= 17 else "evening"
                      for h in hours],
    })


def status_dimension():
    return pd.DataFrame({"OperationalStatus": ["Operating", "Fault", "Maintenance"], "IsOperating": [1, 0, 0]})


def weather_dimension():
    rows = [("unknown",) * 5]
    rows += [(t, w, p, c, s) for t in TEMPERATURE for w in WIND for p in PRECIPITATION for c in CLOUD for s in SUNSHINE]
    return pd.DataFrame(rows, columns=["AvgTemperatureCategory", "AvgWindSpeedCategory", "PrecipitationCategory",
                                       "CloudCoverCategory", "SunshineDurationCategory"])


# ---------------------------------------------------------------- SCD2 dimensions
def source_units(data, snapshot):
    unit = read(data, snapshot, "PowerMaster/Unit.csv")
    model = read(data, snapshot, "PowerMaster/Model.csv")
    manufacturer = read(data, snapshot, "PowerMaster/Manufacturer.csv").rename(
        columns={"Country": "ManufacturerCountry"})
    units = unit.merge(model, on="ModelID").merge(manufacturer, on="ManufacturerID")
    return units[["UnitID", "ZoneID"] + UNIT_ATTRIBUTES]


def scd2(first, second, key, attributes, first_valid_from, change_date, replaced_from=None):
    """Versions of `first` (first snapshot) closed and reopened where `second` (later snapshot) differs."""
    versions = first[[key] + attributes].copy()
    versions["ValidFrom"] = first_valid_from(versions)
    versions["ValidTo"] = OPEN_END
    versions["IsCurrent"] = 1

    merged = second[[key] + attributes].merge(versions, on=key, how="left", suffixes=("", "_old"), indicator=True)
    new_keys = merged[merged["_merge"] == "left_only"]
    old = merged[merged["_merge"] == "both"]
    changed = old[(old[attributes].values != old[[a + "_old" for a in attributes]].values).any(axis=1)]
    changed = changed.rename(columns={"ValidFrom": "ValidFrom_old"})

    changed["ValidFrom"] = change_date
    if replaced_from is not None:
        replaced = replaced_from(changed)
        changed.loc[replaced, "ValidFrom"] = changed.loc[replaced, "InstallationDateTime"]
    closing = changed.set_index(key)["ValidFrom"]
    is_changed = versions[key].isin(closing.index)
    versions.loc[is_changed, "ValidTo"] = versions.loc[is_changed, key].map(closing)
    versions.loc[is_changed, "IsCurrent"] = 0

    added = new_keys[[key] + attributes].copy()
    added["ValidFrom"] = first_valid_from(added)
    changed = changed[[key] + attributes + ["ValidFrom"]].assign(ValidTo=OPEN_END, IsCurrent=1)
    added = added.assign(ValidTo=OPEN_END, IsCurrent=1)
    result = pd.concat([versions, changed, added], ignore_index=True)
    order = result[key].astype(int) if result[key].str.isdigit().all() else result[key]
    return (result.assign(_order=order).sort_values(["_order", "ValidFrom"])
            .drop(columns="_order").reset_index(drop=True))


# ---------------------------------------------------------------- fact
def version_at(readings, versions, key):
    """Surrogate-free SCD2 lookup: the version of `key` valid at the reading time (the first version is open
    to the past), the same rule as the lookup in 03_bulk_load.sql."""
    candidates = readings[["ProductionLogID", key, "LogDateTime"]].merge(
        versions[[key, "ValidFrom", "ValidTo"]].reset_index(names="Version"), on=key)
    candidates = candidates[candidates["ValidTo"] > candidates["LogDateTime"]]
    first = candidates.sort_values("ValidFrom").drop_duplicates("ProductionLogID")
    return first.set_index("ProductionLogID")["Version"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", default=os.path.join(ROOT, "Data"), help="generator output with T1/ and T2/")
    parser.add_argument("--out", default=os.path.join(ROOT, "bulk"), help="target folder")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    log_t1 = read(args.data, "T1", "PowerMaster/ProductionLog.csv")
    log_t2 = read(args.data, "T2", "PowerMaster/ProductionLog.csv")
    last_t1_id = log_t1["ProductionLogID"].astype(int).max()
    # The sources keep no change date: changed attributes are valid from the first day after the T1 readings.
    change_date = (pd.Timestamp(log_t1["LogDateTime"].max()).normalize() + pd.Timedelta(days=1)).strftime(
        "%Y-%m-%d %H:%M:%S")

    days = pd.to_datetime(log_t2["LogDateTime"]).dt.normalize()
    write(date_dimension(days.min(), days.max()), args.out, "Date.csv")
    write(time_dimension(), args.out, "Time.csv")
    write(status_dimension(), args.out, "Status.csv")
    write(weather_dimension(), args.out, "Weather.csv")

    zone_t1 = read(args.data, "T1", "PowerMaster/Zone.csv")
    zone_t2 = read(args.data, "T2", "PowerMaster/Zone.csv")
    zones = scd2(zone_t1, zone_t2, "ZoneID", ["ZoneName", "AreaSizeSqm"],
                 first_valid_from=lambda df: OPEN_START, change_date=change_date)
    write(zones, args.out, "Zone.csv")

    units_t1 = source_units(args.data, "T1")
    units_t2 = source_units(args.data, "T2")
    units = scd2(units_t1, units_t2, "UnitID", UNIT_ATTRIBUTES,
                 first_valid_from=lambda df: df["InstallationDateTime"], change_date=change_date,
                 replaced_from=lambda df: (df["InstallationDateTime"] != df["InstallationDateTime_old"])
                 & (df["InstallationDateTime"] > df["ValidFrom_old"]))
    write(units, args.out, "Unit.csv")

    # Fact: T1 readings with the T1 unit zones, the new T2 readings with the T2 unit zones
    readings = pd.concat([
        log_t1.merge(units_t1[["UnitID", "ZoneID"]], on="UnitID"),
        log_t2[log_t2["ProductionLogID"].astype(int) > last_t1_id].merge(units_t2[["UnitID", "ZoneID"]], on="UnitID"),
    ], ignore_index=True)

    weather = read(args.data, "T2", "Weather/Weather_Data.csv")
    weather["LogDateTime"] = weather["Datetime"].str.replace("T", " ", regex=False)
    weather["AvgTemperatureCategory"] = weather["AvgTemperature"].map(temperature_category)
    weather["AvgWindSpeedCategory"] = weather["AvgWindSpeed"].map(wind_category)
    weather["PrecipitationCategory"] = weather["Precipitation"].map(precipitation_category)
    weather["CloudCoverCategory"] = weather["CloudCover"].map(cloud_category)
    weather["SunshineDurationCategory"] = weather["SunshineDuration"].map(sunshine_category)
    readings = readings.merge(weather.drop(columns="Datetime"), on=["LogDateTime", "ZoneID"], how="left")
    categories = ["AvgTemperatureCategory", "AvgWindSpeedCategory", "PrecipitationCategory",
                  "CloudCoverCategory", "SunshineDurationCategory"]
    no_weather = readings["AvgTemperatureCategory"].isna()
    readings[categories] = readings[categories].fillna("unknown")

    unit_version = version_at(readings, units, "UnitID")
    capacity = readings["ProductionLogID"].map(unit_version).map(units["MaxPowerCapacity"])
    if capacity.isna().any():
        raise SystemExit(f"{capacity.isna().sum()} readings have no valid unit version")
    readings["MaxPossibleEnergy"] = capacity.map(lambda c: f"{Decimal(c):.3f}")

    timestamp = pd.to_datetime(readings["LogDateTime"])
    readings["Date"] = timestamp.dt.strftime("%Y-%m-%d")
    readings["Hour"] = timestamp.dt.hour
    readings = readings.sort_values(["LogDateTime", "UnitID"])
    columns = ["ProductionLogID", "Date", "Hour", "UnitID", "ZoneID", "OperationalStatus"] + categories + [
        "EnergyProduced", "MaxPossibleEnergy",
        "AvgTemperature", "AvgWindSpeed", "Precipitation", "CloudCover", "SunshineDuration"]
    for year, part in readings.groupby(timestamp.dt.year):
        write(part[columns], args.out, f"EnergyProduction_{year}.csv")

    print(f"{'EnergyProduction total':<30} {len(readings):>8} rows "
          f"({int(no_weather.sum())} without weather -> 'unknown')")
    print(f"ValidFrom of changed SCD2 versions: {change_date}")


if __name__ == "__main__":
    main()
