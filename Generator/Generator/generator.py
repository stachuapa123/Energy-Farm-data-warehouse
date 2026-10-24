#!/usr/bin/env python3
"""
EcoVolt data generator
======================

Generates both data sources of the "Energy Production Monitoring" process:

  * PowerMaster  - relational database (MS SQL Server), bulk-load CSV files:
                   Manufacturer, Model, Zone, Unit, ProductionLog
  * Weather_Data - CSV file from the meteorological institute
                   (one row per hour per zone)

in two snapshots:

  * T1  - everything up to --t1-end
  * T2  - T1 + new fact rows up to --t2-end + new dimension rows (new units,
          a new model) + changed dimension rows (manufacturer renamed,
          a unit repowered with a new model, zone areas enlarged)

plus a T2 delta (only the new rows + UPDATE script), so T2 can be produced
either by loading the full T2 snapshot or by applying the delta to T1.

The simulation is physically motivated: weather has seasonal and daily
cycles, synoptic persistence, spatial correlation between zones, heat
waves and cold spells; wind turbines follow a power curve driven by hub-
height wind, PV arrays follow sun geometry, cloudiness, cell temperature,
snow and soiling; all units age (degradation, more faults) and have faults
and planned maintenance.

Usage:
    python generator.py                       # ~500k ProductionLog rows in T2
    python generator.py --target-rows 1000000 # scale up
    python generator.py --help
"""
import argparse
import json
import math
import os
import shutil
from datetime import datetime, timedelta

import numpy as np
import pandas as pd
from scipy.signal import lfilter
from scipy.special import ndtr

# --------------------------------------------------------------------------
# Catalogue
# --------------------------------------------------------------------------
# id, name, code, lat, lon, mean wind @10 m [m/s], wind shear exponent,
# annual mean temp, half annual temp range, coastal, share of wind units
ZONES = [
    (1, "Gdańsk",       "GDA", 54.35, 18.65, 4.8, 0.14,  9.3,  8.8, True,  0.60),
    (2, "Szczecin",     "SZC", 53.43, 14.55, 4.3, 0.16,  9.8,  9.3, True,  0.55),
    (3, "Olsztyn",      "OLS", 53.78, 20.49, 4.1, 0.20,  8.4,  9.8, False, 0.50),
    (4, "Białystok",    "BIA", 53.13, 23.16, 4.0, 0.20,  8.0, 10.3, False, 0.45),
    (5, "Bydgoszcz",    "BYD", 53.12, 18.01, 4.1, 0.19,  9.2,  9.6, False, 0.45),
    (6, "Zielona Góra", "ZGO", 51.94, 15.51, 3.8, 0.20,  9.9,  9.6, False, 0.30),
    (7, "Poznań",       "POZ", 52.41, 16.93, 4.1, 0.19,  9.8,  9.8, False, 0.40),
    (8, "Warszawa",     "WAW", 52.23, 21.01, 3.9, 0.20,  9.4, 10.0, False, 0.35),
]

MANUFACTURERS = [
    (1, "Vestas", "Denmark"),
    (2, "Siemens Gamesa", "Spain"),
    (3, "Nordex", "Germany"),
    (4, "Enercon", "Germany"),
    (5, "JinkoSolar", "China"),
    (6, "LONGi", "China"),
    (7, "Canadian Solar", "Canada"),
    (8, "Trina Solar", "China"),
]
# Manufacturer change applied in T2 (UPDATE in the source system)
MANUFACTURER_CHANGE_T2 = (2, "Siemens Energy", "Germany")

# Exported: id, manufacturer, name, type, lifespan, capacity kW
# Internal: sold from/to year, hub height m, rated wind m/s, cut-in m/s,
#           annual degradation, PV temperature coefficient 1/°C, T2-only flag
MODELS = [
    dict(id=1,  mfr=1, name="V90-2.0 MW",              type="Wind",  life=20, cap=2000, yf=2007, yt=2014, hub=95,  vr=12.5, vci=4.0, degr=0.016),
    dict(id=2,  mfr=1, name="V112-3.45 MW",            type="Wind",  life=25, cap=3450, yf=2013, yt=2019, hub=119, vr=12.0, vci=3.0, degr=0.014),
    dict(id=3,  mfr=1, name="V136-4.2 MW",             type="Wind",  life=25, cap=4200, yf=2018, yt=2026, hub=132, vr=11.0, vci=3.0, degr=0.011),
    dict(id=4,  mfr=2, name="SWT-2.3-108",             type="Wind",  life=20, cap=2300, yf=2010, yt=2016, hub=99,  vr=11.5, vci=3.0, degr=0.015),
    dict(id=5,  mfr=2, name="SG 3.4-132",              type="Wind",  life=25, cap=3400, yf=2016, yt=2026, hub=114, vr=11.0, vci=3.0, degr=0.012),
    dict(id=6,  mfr=3, name="N117/2400",               type="Wind",  life=20, cap=2400, yf=2011, yt=2017, hub=120, vr=11.0, vci=3.0, degr=0.015),
    dict(id=7,  mfr=3, name="N131/3900",               type="Wind",  life=25, cap=3900, yf=2017, yt=2026, hub=134, vr=11.5, vci=3.0, degr=0.012),
    dict(id=8,  mfr=4, name="E-82 E2",                 type="Wind",  life=20, cap=2300, yf=2007, yt=2015, hub=98,  vr=12.5, vci=2.5, degr=0.014),
    dict(id=9,  mfr=4, name="E-138 EP3",               type="Wind",  life=25, cap=4200, yf=2020, yt=2026, hub=131, vr=11.5, vci=2.5, degr=0.010),
    dict(id=10, mfr=7, name="MaxPower Array 500kWp",   type="Solar", life=25, cap=500,  yf=2012, yt=2017, tc=-0.0041, degr=0.0070),
    dict(id=11, mfr=5, name="Eagle Array 600kWp",      type="Solar", life=25, cap=600,  yf=2015, yt=2019, tc=-0.0040, degr=0.0068),
    dict(id=12, mfr=6, name="Hi-MO 4 Array 800kWp",    type="Solar", life=25, cap=800,  yf=2019, yt=2022, tc=-0.0035, degr=0.0055),
    dict(id=13, mfr=8, name="Vertex Array 1000kWp",    type="Solar", life=30, cap=1000, yf=2020, yt=2024, tc=-0.0034, degr=0.0050),
    dict(id=14, mfr=5, name="Tiger Neo Array 1200kWp", type="Solar", life=30, cap=1200, yf=2022, yt=2026, tc=-0.0030, degr=0.0040),
    dict(id=15, mfr=6, name="Hi-MO 6 Array 1000kWp",   type="Solar", life=30, cap=1000, yf=2023, yt=2026, tc=-0.0029, degr=0.0040),
    # new model, appears in T2 only (used for repowering and new units)
    dict(id=16, mfr=6, name="Hi-MO 9 Array 1500kWp",   type="Solar", life=30, cap=1500, yf=2026, yt=2026, tc=-0.0026, degr=0.0035, t2_only=True),
]
MODEL_BY_ID = {m["id"]: m for m in MODELS}

WIND_YEAR_W = {2009: 2, 2010: 3, 2011: 4, 2012: 5, 2013: 5, 2014: 5, 2015: 6, 2016: 5,
               2017: 1, 2018: 1, 2019: 2, 2020: 2, 2021: 3, 2022: 3, 2023: 3, 2024: 3}
SOLAR_YEAR_W = {2013: 1, 2014: 1, 2015: 2, 2016: 2, 2017: 2, 2018: 3, 2019: 4, 2020: 5,
                2021: 5, 2022: 5, 2023: 5, 2024: 4}

STATUS = np.array(["Operating", "Fault", "Maintenance"])


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def ar1(rng, n_series, n, rho, warmup=24 * 40):
    """Stationary AR(1) series with unit variance, shape (n_series, n)."""
    e = rng.standard_normal((n_series, n + warmup))
    y = lfilter([math.sqrt(1 - rho * rho)], [1.0, -rho], e, axis=1)
    return y[:, warmup:]


def hour_index(hours, ts):
    """Index of the first hour >= ts (ts may be outside the range)."""
    return int(np.searchsorted(hours.values, np.datetime64(ts), side="left"))


def solar_geometry(hours, lat, lon, n_sub=6):
    """Mean cos(zenith) clipped at 0, mean clear-sky GHI and share of the
    hour with sun elevation > 3° (WMO sunshine threshold proxy).
    Uses NOAA solar position equations, sub-sampled inside each hour."""
    doy = hours.dayofyear.values.astype(float)
    hr = hours.hour.values.astype(float)
    mu_sum = np.zeros(len(hours))
    ghi_sum = np.zeros(len(hours))
    sun3 = np.zeros(len(hours))
    latr = math.radians(lat)
    for k in range(n_sub):
        minute = (k + 0.5) * 60.0 / n_sub
        g = 2 * math.pi / 365.0 * (doy - 1 + (hr + minute / 60.0 - 12) / 24.0)
        eqt = 229.18 * (0.000075 + 0.001868 * np.cos(g) - 0.032077 * np.sin(g)
                        - 0.014615 * np.cos(2 * g) - 0.040849 * np.sin(2 * g))
        decl = (0.006918 - 0.399912 * np.cos(g) + 0.070257 * np.sin(g)
                - 0.006758 * np.cos(2 * g) + 0.000907 * np.sin(2 * g)
                - 0.002697 * np.cos(3 * g) + 0.00148 * np.sin(3 * g))
        tst = hr * 60 + minute + eqt + 4 * lon
        ha = np.radians(tst / 4.0 - 180.0)
        mu = np.sin(latr) * np.sin(decl) + np.cos(latr) * np.cos(decl) * np.cos(ha)
        mu_c = np.clip(mu, 0, None)
        mu_sum += mu_c
        with np.errstate(divide="ignore", invalid="ignore"):
            ghi = np.where(mu > 0.01, 1098.0 * mu * np.exp(-0.057 / np.maximum(mu, 0.01)), 0.0)
        ghi_sum += ghi
        sun3 += (mu > math.sin(math.radians(3.0)))
    return mu_sum / n_sub, ghi_sum / n_sub, sun3 / n_sub


def bump(n, t0, length, amp):
    """Smooth sin-shaped episode of `length` hours starting at t0."""
    out = np.zeros(n)
    t1 = min(n, t0 + length)
    if t1 <= max(t0, 0):
        return out
    tt = np.arange(max(t0, 0), t1)
    out[tt] = amp * np.sin(np.pi * (tt - t0) / length)
    return out


# --------------------------------------------------------------------------
# Weather
# --------------------------------------------------------------------------
def simulate_weather(hours, rng):
    Z, H = len(ZONES), len(hours)
    doy = hours.dayofyear.values + hours.hour.values / 24.0
    season_cos = np.cos(2 * np.pi * (doy - 20) / 365.25)      # +1 mid-Jan, -1 mid-Jul
    w = (1 + season_cos) / 2                                  # winterness 0..1
    lon = np.array([z[4] for z in ZONES])
    xz = (lon - 18.5) / 4.5                                   # west -0.9 .. east +1

    # synoptic latent fields: common part + east-west gradient + local part
    Pc, Pe = ar1(rng, 1, H, math.exp(-1 / 96)), ar1(rng, 1, H, math.exp(-1 / 96))
    Pl = ar1(rng, Z, H, math.exp(-1 / 48))
    P = 0.75 * Pc + 0.35 * xz[:, None] * Pe + 0.55 * Pl
    P /= np.sqrt(0.75 ** 2 + (0.35 * xz[:, None]) ** 2 + 0.55 ** 2)

    W = 0.70 * ar1(rng, 1, H, math.exp(-1 / 24)) + 0.45 * ar1(rng, Z, H, math.exp(-1 / 12)) - 0.55 * P
    W /= math.sqrt(0.70 ** 2 + 0.45 ** 2 + 0.55 ** 2)

    C = 0.55 * ar1(rng, 1, H, math.exp(-1 / 10)) + 0.60 * ar1(rng, Z, H, math.exp(-1 / 6)) - 0.60 * P
    C /= math.sqrt(0.55 ** 2 + 0.60 ** 2 + 0.60 ** 2)

    sgn = -season_cos                                         # anticyclone: warm summer, cold winter
    Ta = 0.85 * ar1(rng, 1, H, math.exp(-1 / 60)) + 0.50 * ar1(rng, Z, H, math.exp(-1 / 30)) + 0.45 * sgn * P
    Ta /= np.sqrt(0.85 ** 2 + 0.50 ** 2 + (0.45 * sgn) ** 2)

    R = 0.45 * ar1(rng, 1, H, math.exp(-1 / 5)) + 0.90 * ar1(rng, Z, H, math.exp(-1 / 3))
    R /= math.sqrt(0.45 ** 2 + 0.90 ** 2)

    # heat waves (summer) and cold spells (winter), farm-wide
    heat = np.zeros(H)
    cold = np.zeros(H)
    years = sorted(set(hours.year))
    for y in years:
        for _ in range(rng.integers(2, 4)):
            start = pd.Timestamp(y, 6, 10) + pd.Timedelta(days=int(rng.integers(0, 75)))
            heat += bump(H, hour_index(hours, start), int(rng.integers(4, 9)) * 24, rng.uniform(5.0, 8.0))
        for _ in range(rng.integers(1, 3)):
            start = pd.Timestamp(y, 1, 5) + pd.Timedelta(days=int(rng.integers(0, 50)))
            cold += bump(H, hour_index(hours, start), int(rng.integers(4, 10)) * 24, -rng.uniform(4.0, 7.0))
    heat_on = heat / 8.0

    out = {k: np.zeros((Z, H)) for k in
           ["temp", "wind", "precip", "okta", "sunshine", "cf", "sf", "ghi_cs", "mu", "rainfac"]}
    for i, (zid, name, code, lat, lonz, wmean, alpha, tmean, tamp, coast, _) in enumerate(ZONES):
        mu, ghi_cs, sun3 = solar_geometry(hours, lat, lonz)
        hs = (hours.hour.values + 0.5 + lonz / 15.0) % 24      # local solar time, mid-hour

        # clouds: U-shaped okta distribution, cloudier in winter, clearer in heat waves
        m = 0.30 + 1.15 * w + (0.08 if coast else 0.0) - 1.2 * heat_on
        cf = ndtr(1.6 * C[i] + m)
        okta = np.clip(np.rint(8 * cf), 0, 8)
        sf = np.clip(1 - cf ** 1.5 + rng.normal(0, 0.05, H), 0, 1)
        sf[okta >= 8] *= 0.1
        sf[okta <= 0] = np.maximum(sf[okta <= 0], 0.9)

        # precipitation
        q = 0.9 * R[i] + 2.2 * (cf - 0.78)
        rain = q > 1.45
        mean_amt = (0.45 + 0.75 * (1 - w)) * (1 + 0.5 * np.clip(q - 1.45, 0, None))
        amt = rng.gamma(0.75, mean_amt / 0.75)
        precip = np.where(rain, amt, 0.0)

        # temperature
        clim = tmean - tamp * season_cos
        damp = (1.9 + 3.4 * (1 - w)) * (1 - 0.55 * cf) * (0.8 if coast else 1.0)
        diurnal = damp * np.cos(2 * np.pi * (hs - 14.5) / 24)
        sd = 2.6 + 1.8 * w
        ev = heat * (0.85 if coast else (1.1 if lonz < 17 else 1.0)) + cold * (1 + 0.15 * xz[i])
        temp = clim + diurnal + sd * Ta[i] + ev - np.where(rain & (w < 0.5), 1.2, 0.0)

        # wind at 10 m: Weibull through a Gaussian copula
        k = 2.0
        lam = wmean / math.gamma(1 + 1 / k) * (1 + 0.14 * season_cos)
        dw = (0.05 + 0.12 * (1 - w)) * (0.6 if coast else 1.0)
        lam = lam * (1 + dw * np.cos(2 * np.pi * (hs - 14) / 24)) * (1 - 0.15 * heat_on)
        u = np.clip(ndtr(W[i]), 1e-9, 1 - 1e-9)
        wind = lam * (-np.log(1 - u)) ** (1 / k)

        # sunshine minutes, observed after rounding precipitation
        precip = np.round(precip, 1)
        sunshine = np.clip(np.rint(60 * sun3 * np.clip(sf * (1 + rng.normal(0, 0.04, H)), 0, 1)), 0, 60)

        out["temp"][i], out["wind"][i], out["precip"][i] = temp, wind, precip
        out["okta"][i], out["sunshine"][i], out["cf"][i], out["sf"][i] = okta, sunshine, cf, sf
        out["ghi_cs"][i], out["mu"][i] = ghi_cs, mu
        out["rainfac"][i] = np.where(precip >= 0.5, 0.8, 1.0)

    # slowly varying states per zone: snow on panels, soiling, icing of blades
    snow = np.zeros((Z, H)); soil = np.zeros((Z, H)); ice = np.zeros((Z, H))
    s = np.zeros(Z); so = np.full(Z, 0.01); ic = np.zeros(Z)
    month = hours.month.values
    ghi_est = out["ghi_cs"] * (0.22 + 0.78 * out["sf"])
    T, Pr = out["temp"], out["precip"]
    for t in range(H):
        Tt, pt = T[:, t], Pr[:, t]
        s = s + np.where((pt > 0) & (Tt < 0.5), pt * 0.35, 0.0)
        s = s - np.where(Tt > 0.5, 0.015 * (Tt - 0.5), 0.0) - ghi_est[:, t] / 1000 * 0.05
        s = np.clip(s, 0, 1)
        so = so + (0.0024 if month[t] in (4, 5, 6) else 0.0012) / 24
        so = np.where(pt >= 1.0, so * 0.3, so)
        so = np.minimum(so, 0.06)
        ic = ic + np.where((pt > 0) & (Tt > -6) & (Tt < 0.5), 0.25, 0.0)
        ic = ic - np.where(Tt > 1.0, 0.08, 0.004)
        ic = np.clip(ic, 0, 1)
        snow[:, t], soil[:, t], ice[:, t] = s, so, ic
    out["snow"], out["soil"], out["ice"] = snow, soil, ice
    return out


# --------------------------------------------------------------------------
# Units
# --------------------------------------------------------------------------
def pick_model(rng, utype, year, allow_t2=False):
    cands = [m for m in MODELS if m["type"] == utype and m["yf"] <= year <= m["yt"]
             and (allow_t2 or not m.get("t2_only"))]
    if not cands:
        cands = sorted([m for m in MODELS if m["type"] == utype and not m.get("t2_only")],
                       key=lambda m: abs((m["yf"] + m["yt"]) / 2 - year))[:1]
    return cands[int(rng.integers(len(cands)))]["id"]


def random_date(rng, start, end):
    days = (end - start).days
    return start + timedelta(days=int(rng.integers(0, max(days, 1))))


def build_unit_pool(rng, n_pool, start, t1_end):
    """Candidate units in a deterministic order (round-robin over zones)."""
    pool = []
    recent_lo, recent_hi = start + timedelta(days=14), t1_end - timedelta(days=30)
    for r in range(n_pool // len(ZONES) + 1):
        for z in ZONES:
            zid, wshare = z[0], z[10]
            if r == 0:
                utype = "Wind"
            elif r == 1:
                utype = "Solar"
            else:
                utype = "Wind" if rng.random() < wshare else "Solar"
            if rng.random() < 0.12:                                # built during the log period
                inst = random_date(rng, recent_lo, recent_hi)
            else:
                yw = WIND_YEAR_W if utype == "Wind" else SOLAR_YEAR_W
                ys, ws = list(yw), np.array(list(yw.values()), float)
                y = int(rng.choice(ys, p=ws / ws.sum()))
                inst = random_date(rng, datetime(y, 1, 1), datetime(y, 12, 31))
            pool.append(dict(zone=zid, type=utype, install=inst,
                             model=pick_model(rng, utype, inst.year),
                             eff=float(np.clip(rng.normal(1.0, 0.035), 0.9, 1.08)),
                             site=float(np.clip(rng.normal(1.0, 0.045), 0.88, 1.1)),
                             lemon=float(rng.lognormal(0, 0.35))))
            if len(pool) >= n_pool:
                return pool
    return pool


# --------------------------------------------------------------------------
# Production
# --------------------------------------------------------------------------
def wind_power_fraction(v, vci, vr):
    v50 = (vci + vr) / 2 + 0.6
    s = (vr - vci) / 7.0
    L = lambda x: 1 / (1 + np.exp(-(x - v50) / s))
    p = np.clip((L(v) - L(vci)) / (1 - L(vci)), 0, 1)
    p = np.where(v < vci, 0.0, p)
    p = p * np.clip((25.0 - v) / 3.0, 0, 1)                 # storm control / cut-out at 25 m/s
    return p


def simulate_unit(rng, u, hours, wx, t2_end_idx):
    """Return (hour indices, energy kWh, status code) for one unit."""
    H = len(hours)
    zi = u["zone"] - 1
    zone = ZONES[zi]
    i0 = hour_index(hours, u["install"])
    if i0 >= t2_end_idx:
        return None
    idx = np.arange(i0, t2_end_idx)
    n = len(idx)
    hrs = hours.values[idx]

    # model / installation date over time (a repowered unit switches model)
    model_ids = np.full(n, u["model"])
    inst_ts = np.full(n, np.datetime64(u["install"]))
    rp = u.get("repower")
    if rp:
        after = hrs >= np.datetime64(rp["new_install"])
        model_ids[after] = rp["new_model"]
        inst_ts[after] = np.datetime64(rp["new_install"])
    age = (hrs - inst_ts) / np.timedelta64(1, "D") / 365.25
    age = np.clip(age, 0, None)

    T = wx["temp"][zi, idx]
    status = np.zeros(n, dtype=np.int8)
    power = np.zeros(n)

    for mid in np.unique(model_ids):
        m = MODEL_BY_ID[int(mid)]
        sel = model_ids == mid
        degr = (1 - m["degr"]) ** age[sel]
        if m["type"] == "Wind":
            noise = np.exp(0.08 * ar1(rng, 1, n, math.exp(-1 / 6))[0][sel] - 0.0032)
            v = wx["wind"][zi, idx][sel] * (m["hub"] / 10.0) ** zone[6] * u["site"] * noise
            v = v * (288.15 / (T[sel] + 273.15)) ** (1 / 3)        # air density
            p = wind_power_fraction(v, m["vci"], m["vr"])
            p = p * (1 - 0.6 * wx["ice"][zi, idx][sel])
            p = p * u["eff"] * degr * (1 + rng.normal(0, 0.04, sel.sum()))
            power[sel] = np.clip(p, 0, 1) * m["cap"]
        else:
            sf = np.clip(wx["sf"][zi, idx][sel] + 0.07 * ar1(rng, 1, n, math.exp(-1 / 3))[0][sel], 0, 1)
            mu = wx["mu"][zi, idx][sel]
            ghi = wx["ghi_cs"][zi, idx][sel] * (0.25 + 0.75 * sf) * wx["rainfac"][zi, idx][sel]
            poa = ghi * (1 + 0.45 * sf * (1 - mu))                 # tilted south-facing arrays
            tcell = T[sel] + poa / 800.0 * 25.0
            p = poa / 1000.0 * 1.0 * (1 + m["tc"] * (tcell - 25.0))    # system factor calibrated to ~1000 kWh/kWp/yr
            p = p * (1 - wx["snow"][zi, idx][sel]) * (1 - wx["soil"][zi, idx][sel])
            p = p * u["eff"] * degr * (1 + rng.normal(0, 0.02, sel.sum()))
            power[sel] = np.clip(p, 0, 0.98) * m["cap"]

    # ---- planned maintenance (calmest day in the window for turbines)
    years = sorted(set(pd.DatetimeIndex(hrs).year))
    windows = []
    for y in years:
        if u["type"] == "Wind":
            windows += [(datetime(y, 4, 1), 75, (8, 31)), (datetime(y, 9, 1), 60, (8, 31))]
        else:
            windows += [(datetime(y, 3, 15), 75, (4, 10))]
    for ws, span, (dmin, dmax) in windows:
        days = [ws + timedelta(days=int(d)) for d in rng.integers(0, span, 8)]
        if u["type"] == "Wind":
            def daywind(d):
                j = hour_index(hours, d)
                return wx["wind"][zi, j:j + 24].mean() if j < H else 99
            day = min(days, key=daywind)
        else:
            day = days[0]
        st = hour_index(hours, day + timedelta(hours=int(rng.integers(6, 9)))) - i0
        if 0 <= st < n:
            status[st:min(n, st + int(rng.integers(dmin, dmax)))] = 2
    if rp:                                                      # repowering works
        a = hour_index(hours, rp["works_start"]) - i0
        b = hour_index(hours, rp["new_install"]) - i0
        status[max(a, 0):max(b, 0)] = 2

    # ---- faults: age, weather and unit-specific reliability drive the hazard
    life = np.array([MODEL_BY_ID[int(x)]["life"] for x in model_ids])
    agef = (1 + 0.06 * age) * np.where(age > life, 1.5, 1.0) * u["lemon"]
    if u["type"] == "Wind":
        haz = 4.0e-4 * agef * np.where(wx["wind"][zi, idx] > 11, 3.0, 1.0) \
              * (1 + 3.0 * (wx["ice"][zi, idx] > 0.5))
        dmed, major = 12.0, 0.05
    else:
        haz = 1.7e-4 * agef * np.where(T > 30, 3.0, 1.0) * np.where(wx["precip"][zi, idx] > 3, 5.0, 1.0)
        dmed, major = 8.0, 0.05
    cand = np.nonzero(rng.random(n) < haz)[0]
    busy = -1
    for c in cand:
        if c < busy or status[c] != 0:
            continue
        dur = rng.lognormal(math.log(dmed), 0.9)
        if rng.random() < major:                                # gearbox / inverter replacement
            dur *= rng.uniform(5, 12)
        end = min(n, c + max(1, int(round(min(dur, 24 * 21)))))
        seg = status[c:end]
        seg[seg == 0] = 1
        busy = end

    energy = np.where(status == 0, power, 0.0)
    return idx, np.round(energy, 3), status


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="Data", help="output directory (default: Data)")
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--start", default="2025-01-01", help="first logged hour (UTC)")
    ap.add_argument("--t1-end", default="2026-07-01", help="T1 snapshot: data before this moment")
    ap.add_argument("--t2-end", default="2026-10-01", help="T2 snapshot: data before this moment")
    ap.add_argument("--target-rows", type=int, default=500_000,
                    help="approx. ProductionLog rows in T2 (scales the number of units)")
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    start = datetime.fromisoformat(a.start)
    t1_end = datetime.fromisoformat(a.t1_end)
    t2_end = datetime.fromisoformat(a.t2_end)
    assert start < t1_end < t2_end
    hours = pd.date_range(start, t2_end - timedelta(hours=1), freq="h")
    H = len(hours)
    t1_idx, t2_idx = hour_index(hours, t1_end), H

    # ---------------- units: choose how many to hit the target
    pool = build_unit_pool(rng, 600, start, t1_end)
    act = np.array([max(0, H - hour_index(hours, max(p["install"], start))) for p in pool])
    t2_window = t2_idx - t1_idx
    n_sel = 0
    while True:
        n_sel += 1
        n_new = max(3, round(n_sel / 12))
        est = act[:n_sel].sum() + n_new * t2_window * 0.5
        if est >= a.target_rows or n_sel >= len(pool):
            break
    units = pool[:n_sel]

    # make sure both types have units younger than 1 year at T2 (aging questions)
    young_lo = t2_end - timedelta(days=330)
    for utype in ("Wind", "Solar"):
        young = [u for u in units if u["type"] == utype and u["install"] >= young_lo]
        hist = sorted([u for u in units if u["type"] == utype and u["install"] < start],
                      key=lambda u: u["install"], reverse=True)
        for u in hist[:max(0, 2 - len(young))]:
            u["install"] = random_date(rng, young_lo, t1_end - timedelta(days=20))
            u["model"] = pick_model(rng, utype, u["install"].year)

    # IDs: <WT|PV>-<zone code>-<nn>, numbered by installation date
    counters = {}
    for u in sorted(units, key=lambda u: (u["zone"], u["type"], u["install"])):
        key = (u["zone"], u["type"])
        counters[key] = counters.get(key, 0) + 1
        u["id"] = f"{'WT' if u['type'] == 'Wind' else 'PV'}-{ZONES[u['zone'] - 1][2]}-{counters[key]:02d}"
        u["t2_new"] = False

    # ---------------- T2: new units (expansion), mostly in Gdańsk
    new_zones = [1, 1, 7] + [((k * 3) % 8) + 1 for k in range(n_new)]
    new_types = ["Wind", "Solar", "Solar"] + ["Wind" if k % 2 == 0 else "Solar" for k in range(n_new)]
    span = (t2_end - t1_end).days
    for k in range(n_new):
        zid, utype = new_zones[k], new_types[k]
        inst = t1_end + timedelta(days=int(span * (0.15 + 0.7 * k / max(n_new - 1, 1))))
        mid = 3 if utype == "Wind" else 16
        key = (zid, utype)
        counters[key] = counters.get(key, 0) + 1
        units.append(dict(zone=zid, type=utype, install=inst, model=mid, t2_new=True,
                          id=f"{'WT' if utype == 'Wind' else 'PV'}-{ZONES[zid - 1][2]}-{counters[key]:02d}",
                          eff=float(np.clip(rng.normal(1.0, 0.03), 0.92, 1.06)),
                          site=float(np.clip(rng.normal(1.0, 0.04), 0.9, 1.1)),
                          lemon=float(rng.lognormal(0, 0.3))))

    # ---------------- T2: repower the oldest solar array with the new model
    old_solar = sorted([u for u in units if u["type"] == "Solar" and not u["t2_new"]],
                       key=lambda u: u["install"])[0]
    works = t1_end + timedelta(days=int(span * 0.4))
    old_solar["repower"] = dict(new_model=16, works_start=works, new_install=works + timedelta(days=3))

    # ---------------- simulate
    print(f"Hours: {H:,}  units: {len(units)} ({n_sel} in T1, {n_new} new in T2)")
    print("Simulating weather ...")
    wx = simulate_weather(hours, rng)
    print("Simulating production ...")
    parts = []
    for u in sorted(units, key=lambda u: u["id"]):
        r = simulate_unit(rng, u, hours, wx, t2_idx)
        if r is None:
            continue
        idx, e, st = r
        parts.append(pd.DataFrame({"h": idx.astype(np.int32), "UnitID": u["id"], "e": e, "s": st}))
    pl = pd.concat(parts, ignore_index=True).sort_values(["h", "UnitID"], kind="mergesort")
    pl.insert(0, "ProductionLogID", np.arange(1, len(pl) + 1))

    # ---------------- dimension snapshots
    def unit_rows(snapshot):
        rows = []
        for u in sorted(units, key=lambda u: u["id"]):
            if u["t2_new"] and snapshot == "T1":
                continue
            mid, inst = u["model"], u["install"]
            if snapshot == "T2" and u.get("repower"):
                mid, inst = u["repower"]["new_model"], u["repower"]["new_install"]
            rows.append((u["id"], mid, u["zone"], inst.strftime("%Y-%m-%d %H:%M:%S")))
        return pd.DataFrame(rows, columns=["UnitID", "ModelID", "ZoneID", "InstallationDate"])

    def zone_area(unit_list):
        area = {}
        for z in ZONES:
            us = [u for u in unit_list if u["zone"] == z[0]]
            nw = sum(u["type"] == "Wind" for u in us)
            kwp = sum(MODEL_BY_ID[u["model"]]["cap"] for u in us if u["type"] == "Solar")
            area[z[0]] = int(round(60_000 + nw * 280_000 + kwp * 16, -3))
        return area

    area_t1 = zone_area([u for u in units if not u["t2_new"]])
    area_t2 = zone_area(units)

    def zone_df(area):
        return pd.DataFrame([(z[0], z[1], area[z[0]]) for z in ZONES],
                            columns=["ZoneID", "ZoneName", "AreaSizeSqm"])

    def model_df(snapshot):
        return pd.DataFrame([(m["id"], m["mfr"], m["name"], m["type"], m["life"], f"{m['cap']:.2f}")
                             for m in MODELS if snapshot == "T2" or not m.get("t2_only")],
                            columns=["ModelID", "ManufacturerID", "ModelName", "UnitType",
                                     "ExpectedLifespanYears", "MaxPowerCapacity"])

    def mfr_df(snapshot):
        rows = []
        for mid, name, country in MANUFACTURERS:
            if snapshot == "T2" and mid == MANUFACTURER_CHANGE_T2[0]:
                name, country = MANUFACTURER_CHANGE_T2[1], MANUFACTURER_CHANGE_T2[2]
            rows.append((mid, name, country))
        return pd.DataFrame(rows, columns=["ManufacturerID", "ManufacturerName", "Country"])

    # ---------------- weather table
    hour_str_iso = hours.strftime("%Y-%m-%dT%H:%M:%S").values
    hour_str_sql = hours.strftime("%Y-%m-%d %H:%M:%S").values
    Z = len(ZONES)
    weather = pd.DataFrame({
        "h": np.repeat(np.arange(H), Z),
        "Datetime": np.repeat(hour_str_iso, Z),
        "ZoneID": np.tile([z[0] for z in ZONES], H),
        "AvgTemperature": np.round(wx["temp"].T.ravel(), 1),
        "AvgWindSpeed": np.round(wx["wind"].T.ravel(), 1),
        "Precipitation": np.round(wx["precip"].T.ravel(), 1),
        "CloudCover": wx["okta"].T.ravel().astype(int),
        "SunshineDuration": wx["sunshine"].T.ravel().astype(int),
    })
    wcols = ["Datetime", "ZoneID", "AvgTemperature", "AvgWindSpeed", "Precipitation",
             "CloudCover", "SunshineDuration"]

    def pl_out(df):
        return pd.DataFrame({"ProductionLogID": df["ProductionLogID"].values,
                             "UnitID": df["UnitID"].values,
                             "LogDate": hour_str_sql[df["h"].values],
                             "EnergyProduced": df["e"].values,
                             "OperationalStatus": STATUS[df["s"].values]})

    def write(df, path, float_fmt=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        df.to_csv(path, index=False, lineterminator="\n", encoding="utf-8", float_format=float_fmt)

    out = a.out
    if os.path.isdir(out):
        shutil.rmtree(out)
    pl_t1 = pl[pl["h"] < t1_idx]
    pl_new = pl[pl["h"] >= t1_idx]
    counts = {}
    for snap, pld, wd in (("T1", pl_t1, weather[weather["h"] < t1_idx]), ("T2", pl, weather)):
        base = os.path.join(out, snap)
        write(mfr_df(snap), f"{base}/PowerMaster/Manufacturer.csv")
        write(model_df(snap), f"{base}/PowerMaster/Model.csv")
        write(zone_df(area_t1 if snap == "T1" else area_t2), f"{base}/PowerMaster/Zone.csv")
        write(unit_rows(snap), f"{base}/PowerMaster/Unit.csv")
        print(f"Writing {snap} ProductionLog ({len(pld):,} rows) ...")
        write(pl_out(pld), f"{base}/PowerMaster/ProductionLog.csv", "%.3f")
        write(wd[wcols], f"{base}/Weather/Weather_Data.csv", "%.1f")
        counts[snap] = dict(ProductionLog=len(pld), Weather_Data=len(wd),
                            Unit=len(unit_rows(snap)), Model=len(model_df(snap)),
                            Manufacturer=len(MANUFACTURERS), Zone=len(ZONES))

    # ---------------- T2 delta (to apply on a database loaded with T1)
    dbase = os.path.join(out, "T2_delta")
    m2 = model_df("T2")
    write(m2[~m2["ModelID"].isin(model_df("T1")["ModelID"])], f"{dbase}/PowerMaster/Model_new.csv")
    u2 = unit_rows("T2")
    write(u2[u2["UnitID"].isin([u["id"] for u in units if u["t2_new"]])], f"{dbase}/PowerMaster/Unit_new.csv")
    write(pl_out(pl_new), f"{dbase}/PowerMaster/ProductionLog_new.csv", "%.3f")
    write(weather[weather["h"] >= t1_idx][wcols], f"{dbase}/Weather/Weather_Data_new.csv", "%.1f")

    rp_u = old_solar
    old_name = [m for m in MANUFACTURERS if m[0] == MANUFACTURER_CHANGE_T2[0]][0]
    updates = [
        f"UPDATE dbo.Manufacturer SET ManufacturerName = '{MANUFACTURER_CHANGE_T2[1]}', Country = '{MANUFACTURER_CHANGE_T2[2]}' "
        f"WHERE ManufacturerID = {MANUFACTURER_CHANGE_T2[0]};   -- was '{old_name[1]}', '{old_name[2]}'",
        f"UPDATE dbo.Unit SET ModelID = {rp_u['repower']['new_model']}, "
        f"InstallationDate = '{rp_u['repower']['new_install'].strftime('%Y-%m-%dT%H:%M:%S')}' "
        f"WHERE UnitID = '{rp_u['id']}';   -- repowered, was ModelID {rp_u['model']}, "
        f"installed {rp_u['install'].strftime('%Y-%m-%d')}",
    ]
    for z in ZONES:
        if area_t1[z[0]] != area_t2[z[0]]:
            updates.append(f"UPDATE dbo.Zone SET AreaSizeSqm = {area_t2[z[0]]} WHERE ZoneID = {z[0]};"
                           f"   -- {z[1]} extended, was {area_t1[z[0]]}")
    with open(f"{dbase}/PowerMaster/apply_T2_delta.sql", "w", encoding="utf-8-sig", newline="\n") as f:
        f.write(DELTA_SQL.replace("{{UPDATES}}", "\n".join(updates)))

    changes = dict(
        new_models=m2[~m2["ModelID"].isin(model_df("T1")["ModelID"])].to_dict("records"),
        new_units=u2[u2["UnitID"].isin([u["id"] for u in units if u["t2_new"]])].to_dict("records"),
        manufacturer_changed=dict(ManufacturerID=MANUFACTURER_CHANGE_T2[0],
                                  before=dict(ManufacturerName=old_name[1], Country=old_name[2]),
                                  after=dict(ManufacturerName=MANUFACTURER_CHANGE_T2[1], Country=MANUFACTURER_CHANGE_T2[2])),
        unit_repowered=dict(UnitID=rp_u["id"],
                            before=dict(ModelID=rp_u["model"], InstallationDate=str(rp_u["install"])),
                            after=dict(ModelID=rp_u["repower"]["new_model"],
                                       InstallationDate=str(rp_u["repower"]["new_install"])),
                            maintenance_from=str(rp_u["repower"]["works_start"])),
        zones_extended=[dict(ZoneID=z[0], ZoneName=z[1], before=area_t1[z[0]], after=area_t2[z[0]])
                        for z in ZONES if area_t1[z[0]] != area_t2[z[0]]],
    )
    meta = dict(seed=a.seed, start=a.start, t1_end=a.t1_end, t2_end=a.t2_end,
                target_rows=a.target_rows, counts=counts,
                delta_rows=dict(ProductionLog=len(pl_new), Weather_Data=int((weather["h"] >= t1_idx).sum())),
                t2_changes=changes)
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False, default=str)
    shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "load_snapshot.sql"),
                os.path.join(out, "load_snapshot.sql"))

    print(json.dumps(dict(counts=counts, delta=meta["delta_rows"]), indent=2))
    print(f"Done -> {os.path.abspath(out)}")


DELTA_SQL = r"""/* EcoVolt PowerMaster - apply the T2 delta on a database loaded with T1.
   Order: new dimension rows -> UPDATEs of changed dimension rows -> new facts.
   Set @dir to the folder with the *_new.csv files (path on the SQL Server machine). */
USE PowerMaster;
SET NOCOUNT ON;

DECLARE @dir  NVARCHAR(400) = N'C:\EcoVolt\Data\T2_delta\PowerMaster\';
DECLARE @opts NVARCHAR(400) = N''' WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'', KEEPIDENTITY, CHECK_CONSTRAINTS, TABLOCK);';

BEGIN TRANSACTION;

/* 1. new dimension rows */
EXEC (N'BULK INSERT dbo.Model FROM ''' + @dir + N'Model_new.csv' + @opts);
EXEC (N'BULK INSERT dbo.Unit  FROM ''' + @dir + N'Unit_new.csv'  + @opts);

/* 2. changes of existing dimension rows */
{{UPDATES}}

/* 3. new fact rows */
EXEC (N'BULK INSERT dbo.ProductionLog FROM ''' + @dir + N'ProductionLog_new.csv' + @opts);

COMMIT;

SELECT 'Manufacturer' AS TableName, COUNT(*) AS RowsCount FROM dbo.Manufacturer UNION ALL
SELECT 'Model', COUNT(*) FROM dbo.Model UNION ALL
SELECT 'Zone', COUNT(*) FROM dbo.Zone UNION ALL
SELECT 'Unit', COUNT(*) FROM dbo.Unit UNION ALL
SELECT 'ProductionLog', COUNT(*) FROM dbo.ProductionLog;
"""

if __name__ == "__main__":
    main()
