# EcoVolt Data Warehouse – implementation

Authors: Stanisław Apanasiewicz 198169, Kacper Neumann 203394

This is the data warehouse (MS SQL Server 2022 on Linux) and the semantic layer
(Cube Core) for the *Energy Production Monitoring* process. It follows the
structure of the course template.

```
implementation/
  docker-compose.yml          SQL Server 2022 + Cube; works on native Linux and on WSL2
  .env                        passwords, data folder, Cube connection
  run_sql.sh                  runs the scripts with sqlcmd (in the container or locally)
  without_partitions/         01 create · 02 descriptions · 03 bulk load T1 · 04 dims / facts
                              constraints and indexes · 05 FlatTable view · 06 FLAT_TABLE ·
                              07 incremental load T2 · 08 validation + 10 queries
  with_partitions/            00 partitions · 01_0 create · 01_01 partitioned CCI · 02_0 … 08_0
  09_compare_partitioned_vs_not.sql   partitioned vs non-partitioned (STATISTICS IO/TIME)
  model/energy_production.cube.yml    semantic layer (Cube)
  queries/                    the 10 Playground queries (JSON) + PLAYGROUND_QUERIES.md
```

The two variants build separate databases: **EcoVoltDW** (without partitions)
and **EcoVoltDW_Part** (with partitions). Both can live on one server, which is
what `09_compare_partitioned_vs_not.sql` needs.

## Quick start (Linux and WSL)

1. Put this folder next to the generator's `Data` folder, or set `DATA_DIR` in
   `.env` to wherever `Data` is. `Data` must contain `T1/` and `T2/`.
2. Start the containers:
   ```bash
   docker compose up -d
   ```
   SQL Server takes about 30 s to become healthy. Cube starts after it.
3. Run the scripts:
   ```bash
   ./run_sql.sh without_partitions           # T1 (2024): 01 → 06
   ./run_sql.sh without_partitions 07 08     # T2 (2025) incremental, validation + 10 queries
   ./run_sql.sh with_partitions              # same for the partitioned variant
   ./run_sql.sh with_partitions 07 08
   ./run_sql.sh . 09                         # comparison
   ```
4. Open http://localhost:4000 (Cube Playground) and run the queries from
   `queries/` (see `queries/PLAYGROUND_QUERIES.md`).

To connect from SSMS, Azure Data Studio or VS Code, use `localhost,1433`, user
`sa`, the password from `.env`, and *Trust server certificate*. You can also
run the scripts there in the order above, instead of with `run_sql.sh`.

Expected row counts after T2 (default generator output):
* DATE 731
* ZONE 10
* UNIT 46: 42 units + 3 versions from the Siemens rename + 1 from the PV-POZ-01 repowering
* ENERGY_PRODUCTION, FlatTable and FLAT_TABLE: 665,832 each

## Notes for WSL (Windows)

* **Docker:** either Docker Desktop with *WSL integration* enabled for your
  distro, or Docker Engine installed inside the distro. The commands are the
  same for both.
* **Keep the project inside the WSL file system** (`~/...`), not under
  `/mnt/c/...`. Bind mounts from NTFS are slow. The database files live in the
  named volume `mssql-data`, so NTFS permissions never matter for them.
* **Line endings:** files must have LF endings (`.gitattributes` enforces this
  in git). If `run_sql.sh` fails with `$'\r': command not found`, run
  `sed -i 's/\r$//' run_sql.sh .env`. The CSVs from the generator already use LF,
  which matches `ROWTERMINATOR = '0x0a'`.
* **From Windows:** reach SQL Server at `localhost,1433` and the Playground at
  http://localhost:4000. WSL2 forwards `localhost` automatically.
* **Memory:** SQL Server needs at least 2 GB of RAM. If WSL has less, raise
  `memory=` in `%UserProfile%\.wslconfig`.

## Notes for native Linux

* Docker Engine with the compose plugin; your user must be in the `docker` group.
* The container runs as user `mssql` (uid 10001), so it must be able to read the
  CSVs. If needed, run `chmod -R a+rX ../Data`.
* **SELinux (Fedora/RHEL):** change `:ro` to `:ro,z` on the two bind mounts in
  `docker-compose.yml`.
* **SQL Server installed directly on the host** (no SQL Server container):
  1. Make the CSVs visible under the same path the scripts use:
     `sudo ln -s "$(realpath ../Data)" /dw_data`. The `mssql` user must be able
     to read them.
  2. In `.env`, set `MSSQL_IN_DOCKER=false`. `run_sql.sh` then uses your local
     `sqlcmd`.
  3. In `.env`, set `CUBEJS_DB_HOST=host.docker.internal`, then start only Cube
     with `docker compose up -d --no-deps cube`.
  4. SQL Server must accept TCP connections from the Docker bridge network.
     Check your firewall (ufw) for port 1433.

## Design notes

* **Naming:** tables follow the template: upper-case names (ENERGY_PRODUCTION,
  UNIT, ZONE, STATUS, WEATHER, DATE, TIME) with the column names of our
  relational design.
* **Loading:**
  * The load reads the generator CSVs directly (`/dw_data/T1/...`, then
    `/dw_data/T2/...`), the same way the template stages its CSVs into `#Stage`
    tables.
  * Dates are staged as text and converted with explicit styles, so the load
    doesn't depend on the server language.
* **Index pipeline:** the lecture's pipeline is followed.
  * Initial load: load the heap → 04 builds PKs, the ordered CCI, FKs and NCIs.
  * Incremental load (07): disable the fact FKs and NCIs → load → rebuild →
    REORGANIZE the CCI → FKs `WITH CHECK`.
  * The partitioned variant creates its CCI before the load, as in the template
    (01_01).
* **Columnstore:** `CREATE CLUSTERED COLUMNSTORE INDEX ... ORDER (DateKey)`
  sorts the rowgroups by date, which gives segment elimination. This needs
  SQL Server 2022, which is why the image is `2022-latest`.
* **Partitions:**
  * yearly, on `DateKey` (yyyymmdd);
  * no extra date column is needed, unlike the template's `SaleDate`;
  * 2024 holds about 311k rows and 2025 about 355k, both enough for compressed
    rowgroups;
  * unique indexes are aligned, so they include `DateKey`.
* **SCD2:**
  * Changed attributes get ValidFrom = the first day after the readings already
    loaded (2025-01-01). The sources keep no change date.
  * A replaced unit (PV-POZ-01) gets its new installation date.
  * Each reading points to the version valid at its time.
* **Flat table:**
  * `OlderUnit` = age ≥ 5 whole years, which matches the 5-10 / over 10 age categories.
  * `OldestWindTurbine` is flagged by UnitID, so the SCD2 versions keep the flag.
  * The daily weather classes use one value per zone and hour, so they aren't
    weighted by the number of units.
* **Cube:**
  * camelCase members with descriptions, as in the template;
  * month-over-month and year-over-year use `multi_stage` + `time_shift`, as in
    the template;
  * rolling-window variants are kept as a fallback.

## What was tested here

* **All T-SQL scripts** (both variants and the comparison) pass Microsoft's
  T-SQL parser (ScriptDom, through tsqllint). They were **not** executed on a
  SQL Server, so check the output of `08_validation_and_queries.sql`.
* **`docker-compose.yml`** validates with `docker compose config`.
  **`run_sql.sh`** passes shellcheck, and a dry run with a stub `sqlcmd` picked
  the right scripts in the right order.
* **The Cube model** was compiled by Cube's schema compiler. All 12 queries ran
  on a 665,832-row synthetic copy of the flat table. Previous month and same
  month last year (both the `time_shift` and the rolling-window variants) match
  manual sums. The SQL Cube generates for SQL Server passes the T-SQL parser.
