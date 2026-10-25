#!/usr/bin/env python3
"""Sanity and realism checks of the generated data (python validate.py [Data])."""
import os
import sys

import numpy as np
import pandas as pd

D = sys.argv[1] if len(sys.argv) > 1 else "Data"
ok = True


def check(cond, msg):
    global ok
    print(("  OK   " if cond else "  FAIL ") + msg)
    ok &= bool(cond)


def load(snap):
    p = f"{D}/{snap}/PowerMaster"
    t = {n: pd.read_csv(f"{p}/{n}.csv", encoding="utf-8") for n in
         ["Manufacturer", "Model", "Zone", "Unit", "ProductionLog"]}
    t["Weather"] = pd.read_csv(f"{D}/{snap}/Weather/Weather_Data.csv")
    return t


t1, t2 = load("T1"), load("T2")

print("== Integrity")
for name, t in (("T1", t1), ("T2", t2)):
    pl, u, m, w = t["ProductionLog"], t["Unit"], t["Model"], t["Weather"]
    check(pl["ProductionLogID"].is_unique and u["UnitID"].is_unique, f"{name}: primary keys unique")
    check(pl["UnitID"].isin(u["UnitID"]).all(), f"{name}: ProductionLog.UnitID -> Unit")
    check(u["ModelID"].isin(m["ModelID"]).all() and u["ZoneID"].isin(t["Zone"]["ZoneID"]).all(),
          f"{name}: Unit -> Model, Zone")
    check(m["ManufacturerID"].isin(t["Manufacturer"]["ManufacturerID"]).all(), f"{name}: Model -> Manufacturer")
    check(not pl.duplicated(["UnitID", "LogDate"]).any(), f"{name}: one reading per unit and hour")
    check(not w.duplicated(["Datetime", "ZoneID"]).any(), f"{name}: one weather row per zone and hour")
    check(u["UnitID"].str.len().max() <= 10 and t["Zone"]["ZoneName"].str.len().max() <= 15
          and m["ModelName"].str.len().max() <= 50, f"{name}: VARCHAR lengths fit")
    check(set(pl["OperationalStatus"]) <= {"Operating", "Fault", "Maintenance"}, f"{name}: status domain")
    check((pl["EnergyProduced"] >= 0).all() and pl.notna().all().all() and w.notna().all().all(),
          f"{name}: no negatives / NULLs")
    key = pl.merge(u, on="UnitID")
    key["Datetime"] = key["LogDate"].str.replace(" ", "T")
    j = key.merge(w, on=["Datetime", "ZoneID"], how="left")
    check(j["AvgTemperature"].notna().all(), f"{name}: every reading has a weather row (ZoneID + hour)")
    inst = pd.to_datetime(key["InstallationDate"]) if name == "T1" else None
    if name == "T1":
        check((pd.to_datetime(key["LogDate"]) >= inst).all(), "T1: no readings before installation")

print("\n== T1 -> T2")
p1, p2 = t1["ProductionLog"], t2["ProductionLog"]
check(p2.head(len(p1)).reset_index(drop=True).equals(p1), "T1 ProductionLog is an exact prefix of T2")
check(t2["Weather"].head(len(t1["Weather"])).reset_index(drop=True).equals(t1["Weather"]),
      "T1 Weather is an exact prefix of T2")
check(len(t2["Unit"]) > len(t1["Unit"]) and len(t2["Model"]) > len(t1["Model"]), "new Unit and Model rows in T2")
for n, k in (("Manufacturer", "ManufacturerID"), ("Zone", "ZoneID"), ("Unit", "UnitID")):
    a = t1[n].set_index(k)
    b = t2[n].set_index(k).loc[a.index]
    ch = (a != b).any(axis=1)
    print(f"  changed {n} rows: {ch.sum()}")
    for i in a.index[ch]:
        print(f"     {i}: {a.loc[i].to_dict()} -> {b.loc[i].to_dict()}")

# delta reproduces T2
dl = f"{D}/T2_delta/PowerMaster"
pn = pd.read_csv(f"{dl}/ProductionLog_new.csv")
check(pd.concat([p1, pn], ignore_index=True).equals(p2), "T1 + ProductionLog_new == T2 ProductionLog")

print("\n== Weather realism (T2, per zone)")
w = t2["Weather"].merge(t2["Zone"], on="ZoneID")
w["dt"] = pd.to_datetime(w["Datetime"])
w["month"] = w["dt"].dt.month
y25 = w[w["dt"].dt.year == 2025]
summ = y25.groupby("ZoneName").agg(
    T_year=("AvgTemperature", "mean"),
    T_jan=("AvgTemperature", lambda s: s[y25.loc[s.index, "month"] == 1].mean()),
    T_jul=("AvgTemperature", lambda s: s[y25.loc[s.index, "month"] == 7].mean()),
    T_min=("AvgTemperature", "min"), T_max=("AvgTemperature", "max"),
    hours_over30=("AvgTemperature", lambda s: (s > 30).sum()),
    wind_mean=("AvgWindSpeed", "mean"), wind_max=("AvgWindSpeed", "max"),
    precip_mm=("Precipitation", "sum"), rain_hours_pct=("Precipitation", lambda s: 100 * (s > 0).mean()),
    cloud_mean=("CloudCover", "mean"), sunshine_h=("SunshineDuration", lambda s: s.sum() / 60),
).round(1)
print("  calendar year 2025:")
print(summ.to_string())
print("\n  CloudCover distribution (% of hours):",
      (w["CloudCover"].value_counts(normalize=True).sort_index() * 100).round(1).to_dict())
wd = w.groupby(["ZoneName", w["dt"].dt.date]).agg(wind=("AvgWindSpeed", "mean"), cc=("CloudCover", "mean"))
print("  days with daily mean wind > 30 km/h (8.33 m/s):", (wd["wind"] > 8.33).groupby("ZoneName").sum().to_dict())
print("  days 'Sunny' (daily mean CloudCover < 2):", (wd["cc"] < 2).groupby("ZoneName").sum().to_dict())
print("  days 'Cloudy' (daily mean CloudCover > 6):", (wd["cc"] > 6).groupby("ZoneName").sum().to_dict())

print("\n== Production realism (T2)")
pl = p2.merge(t2["Unit"], on="UnitID").merge(t2["Model"], on="ModelID")
pl["dt"] = pd.to_datetime(pl["LogDate"])
avail = pl.groupby("UnitType")["OperationalStatus"].value_counts(normalize=True).unstack().round(4) * 100
print("  status share %:\n" + avail.to_string())
# use T1 dimension state for capacity (repowering changes capacity in T2)
plc = p2.merge(t1["Unit"], on="UnitID", how="inner").merge(t1["Model"], on="ModelID")
plc = plc[pd.to_datetime(plc["LogDate"]).dt.year == 2025]
cf = plc.groupby(["UnitType"]).apply(
    lambda g: g["EnergyProduced"].sum() / (g["MaxPowerCapacity"].sum()), include_groups=False)
print("  2025 capacity factor:", (cf * 100).round(1).to_dict(), "%  (PL typical: wind 25-30, PV 10-12)")
cfz = plc.groupby(["UnitType", "ZoneID"]).apply(
    lambda g: 100 * g["EnergyProduced"].sum() / g["MaxPowerCapacity"].sum(), include_groups=False).round(1)
print("  by zone:\n" + cfz.unstack().to_string())
pl["month"] = pl["dt"].dt.to_period("M")
mon = pl.groupby(["month", "UnitType"])["EnergyProduced"].sum().unstack() / 1e6
print("  monthly energy [GWh]:\n" + mon.round(2).to_string())

# daily correlation wind speed vs turbine energy
pz = pl[pl["UnitType"] == "Wind"].copy()
pz["Datetime"] = pz["LogDate"].str.replace(" ", "T")
pz = pz.merge(t2["Weather"], on=["Datetime", "ZoneID"])
pz["d"] = pz["dt"].dt.date
dd = pz.groupby(["UnitID", "d"]).agg(e=("EnergyProduced", "sum"), v=("AvgWindSpeed", "mean"),
                                       op=("OperationalStatus", lambda s: (s == "Operating").all()))
r = dd[dd["op"]].groupby("UnitID").apply(lambda g: g["e"].corr(g["v"]), include_groups=False)
print(f"  Pearson r daily wind vs energy per turbine: min {r.min():.2f}, median {r.median():.2f}, max {r.max():.2f}")

ps = pl[pl["UnitType"] == "Solar"].copy()
ps["Datetime"] = ps["LogDate"].str.replace(" ", "T")
ps = ps.merge(t2["Weather"], on=["Datetime", "ZoneID"])
ps["d"] = ps["dt"].dt.date
ds = ps.groupby(["UnitID", "d"]).agg(e=("EnergyProduced", "sum"), cc=("CloudCover", "mean"),
                                       cap=("MaxPowerCapacity", "first"))
ds["kwh_per_kwp"] = ds["e"] / ds["cap"]
print(f"  PV daily yield kWh/kWp: sunny days {ds[ds.cc < 2].kwh_per_kwp.mean():.2f} vs cloudy days "
      f"{ds[ds.cc > 6].kwh_per_kwp.mean():.2f}")

# aging
age = p2.merge(t1["Unit"], on="UnitID").merge(t1["Model"], on="ModelID")
age = age[pd.to_datetime(age["LogDate"]) < "2026-07-01"]
g = age.groupby(["UnitID", "UnitType", "InstallationDate"]).apply(
    lambda x: x["EnergyProduced"].sum() / x["MaxPowerCapacity"].iloc[0] / len(x), include_groups=False).rename("cf").reset_index()
g["age"] = (pd.Timestamp("2026-07-01") - pd.to_datetime(g["InstallationDate"])).dt.days / 365.25
for ty in ("Wind", "Solar"):
    x = g[g.UnitType == ty]
    slope = np.polyfit(x["age"], x["cf"] / x["cf"].mean(), 1)[0] * 100
    print(f"  {ty}: units {len(x)}, >5y {(x.age > 5).sum()}, <1y {(x.age < 1).sum()}, "
          f"relative CF change per year of age {slope:.2f}%")
hot = ps[(ps["AvgTemperature"] > 30)]
print(f"  PV readings with T > 30°C: {len(hot)}; wind readings with T > 30°C: "
      f"{(pz['AvgTemperature'] > 30).sum()}")

print("\nALL CHECKS PASSED" if ok else "\nSOME CHECKS FAILED")
