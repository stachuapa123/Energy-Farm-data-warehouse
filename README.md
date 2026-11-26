# EcoVolt Data Warehouse

Authors: Stanisław Apanasiewicz 198169, Kacper Neumann 203394

This is the implementation of the data warehouse and the semantic layer for the *Energy Production Monitoring* process of the EcoVolt renewable energy farm. The warehouse is a star schema in SQL Server: the fact table EnergyProduction (one reading of one unit within one hour) with the dimensions Unit (SCD2), Zone (SCD2), Status, Weather (junk), Date and Time. It demonstrates bulk loading, dimensional modeling, indexing, optional date-based partitioning, and a denormalized flat view or table. Cube exposes the flat table as a semantic layer with measures such as total energy, capacity factor and availability, and with dimensions for grouping and filtering.

## Project layout

- `docker-compose.yml`: SQL Server and Cube services and their configuration.
- `bulk/`: sample CSV files used to populate the warehouse, one per table (built by `Generator/export_bulk.py`).
- `dw_creation_scripts/with_partitions/`: SQL scripts for the partitioned warehouse (database `EcoVoltDW_Part`), including a partitioned fact table and flat table.
- `dw_creation_scripts/without_partitions/`: SQL scripts for the warehouse without partitioning (database `EcoVoltDW`).
- `dw_creation_scripts/compare_partitioned_vs_not.sql`: partitioned vs non-partitioned queries (needs both databases).
- `cube/schema/`: Cube semantic model of the energy production.
- `queries/`: the 10 Cube Playground queries of the requirements specification (`PLAYGROUND_QUERIES.md`, `q*.json`) and the same queries in SQL (`sql_crosscheck.sql`).
- `docs/`: business process, requirements, relational and semantic layer design documents.
- `Data/`, `Generator/`, `Schemas/`: the generated source data (snapshots T1 and T2), its generator, and the source system schemas (PowerMaster, Weather_Data).
- `run.sh`: optional helper that runs the SQL scripts below with `sqlcmd` inside the container.

### Mapping to the assignment subtasks

1. Relational model: `01_create_tables.sql` / `01_0_create_tables.sql`, descriptions in `02_*`.
2. Sample data: `bulk/*.csv`, loaded by `03_bulk_load.sql` / `03_0_bulk_load.sql`.
3. Flat tables: the non-materialized view `dbo.FlatTable` (`05_*`) and the table `dbo.FlatTablePhysical` (`06_*`).
4. Partitioned and non-partitioned versions with indexes: `00_prepare_partitions.sql`, `01_01_fact_CCI_partitioned.sql`, the `04_*` scripts and `compare_partitioned_vs_not.sql`.
5. Semantic layer: `cube/schema/energy_production.cube.yml`.
6. Queries in Cube Playground: `queries/`.

## Getting started

### Requirements

- Docker and Docker Compose.
- A SQL Server client that supports `GO` batches, such as SQL Server Management Studio, Azure Data Studio, VS Code with the mssql extension, or `sqlcmd`.
- Available local ports 1433 and 4000.

### Start the services

From the project directory, run:

```sh
docker compose up -d
```

Wait for SQL Server to finish starting, then connect to `localhost,1433` using SQL Server authentication (tick *Trust server certificate*). The demonstration credentials in the Compose configuration are username `sa` and password `EcoVolt_Strong_Pass_2025`. These credentials and the Cube API secret are for local demonstration only, not production.

Docker Compose mounts `bulk/` at `/dw_data/bulk` inside SQL Server, where the bulk-load scripts expect the CSV files. The services start automatically, but the SQL scripts must be run manually.

### Initialize the warehouse

Run the scripts of one or both directories with your SQL client. The two variants create separate databases (`EcoVoltDW` and `EcoVoltDW_Part`), so both can live on one server, which `compare_partitioned_vs_not.sql` needs. Start with a fresh database: the sample load requires empty target tables, and some setup statements cannot be rerun unchanged.

For `dw_creation_scripts/without_partitions/`:

1. Run `01_create_tables.sql`, then `02_extended_properties.sql` and `03_bulk_load.sql`.
2. Use the appropriate creation sections from the `04_` files as described below, then run `05_flat_table_view.sql`.
3. Optionally run `06_flat_table.sql` to create and populate a physical flat table from the view.

For `dw_creation_scripts/with_partitions/`:

1. Run `00_prepare_partitions.sql`, then `01_0_create_tables.sql` and `01_01_fact_CCI_partitioned.sql`. The partitioned columnstore index must exist before the load.
2. Run `02_0_extended_properties.sql` and `03_0_bulk_load.sql`.
3. Use the appropriate creation sections from the `04_` files as described below, then run `05_0_flat_table_view.sql`.
4. Optionally run `06_0_flat_table.sql` to create and populate a physical flat table from the view.

With both variants loaded, run `dw_creation_scripts/compare_partitioned_vs_not.sql` (with the actual execution plan turned on) to compare them, and `queries/sql_crosscheck.sql` to validate the data and compute the 10 queries in SQL.

The bulk load is a simplified demonstration designed for the supplied sample data, not a production ETL pipeline. Expected row counts: Date 731, Time 24, Status 3, Weather 1201, Zone 10, Unit 45 (42 units + 3 versions of the Siemens Gamesa -> Siemens Energy change), EnergyProduction, FlatTable and FlatTablePhysical 665,832 each.

Instead of running the scripts one by one, `run.sh` runs the same order with `sqlcmd` inside the container (`./run.sh --reset without with compare`).

### Using the `04_` scripts

The `04_` files are collections of SQL instructions to use at the appropriate points in an ETL process, **not consecutive steps to run in full for a single final result**. Each variant contains separate dimension and fact scripts with sections for creating constraints and indexes, disabling selected constraints and indexes before a load, and rebuilding and re-enabling them afterward.

For the initial load above, execute the creation sections of the dimension script first, followed by those of the fact script. Do not execute the disable and rebuild sections as part of that initial setup (running them right after the creation sections, as `run.sh` does, only rebuilds the fresh indexes). For an ETL process that uses existing constraints and indexes, select the relevant disable statements before loading and the corresponding rebuild and re-enable statements afterward.

In the partitioned variant, the fact clustered columnstore index is created separately by `01_01_fact_CCI_partitioned.sql`; in the unpartitioned variant, its creation is in the fact `04_` script.

### Explore the semantic layer

After creating the warehouse and the `dbo.FlatTable` view, open the Cube development interface at <http://localhost:4000>. The configured `EnergyProduction` model uses the view of `EcoVoltDW` by default.

- To use the optional physical table instead, change `sql_table` in `cube/schema/energy_production.cube.yml` to `dbo.FlatTablePhysical`.
- To use the partitioned variant, set `CUBEJS_DB_NAME=EcoVoltDW_Part` in `docker-compose.yml` and run `docker compose up -d cube`.

The 10 queries of the requirements specification are described in `queries/PLAYGROUND_QUERIES.md`; paste the `queries/q*.json` files into the Playground query builder, run them and keep screenshots of the results for the presentation. The current month is the last full month of data (December 2025) and the last quarter is the last full quarter (Q4 2025).

Month-over-month and year-over-year values (`previousMonthEnergy`, `energyChangeVsPreviousMonth`, `sameMonthLastYearEnergy`, `energyChangeVsSameMonthLastYear`) need `readingDate` with **month** granularity. Avoid filtering on `productionYear` or `productionMonth`, since those filters also restrict the shifted period; use the `readingDate` date range instead. Multi-stage time shifts require Cube's Tesseract engine (enabled by default from Cube v1.7.0).

### Regenerate the sample data

`bulk/` is built from the generator output in `Data/` (snapshots T1 and T2) by applying the ETL mapping of the relational design: generated Date, Time, Status and Weather; SCD2 versions of Zone and Unit (changes found in T2 are valid from 2025-01-01); the weather of every reading, raw and categorized; MaxPossibleEnergy of the unit version valid at the reading. From the project directory:

```sh
python Generator/export_bulk.py
```

It needs Python 3.9+ with pandas (or `uv run --with pandas python Generator/export_bulk.py`). Rerun the warehouse scripts on a fresh database afterwards.

### Stop the services

```sh
docker compose down
```

The SQL Server data remains in the `mssql_data` Docker volume after the services stop (`docker compose down -v` deletes it).

## Design notes

- **Naming:** tables and columns follow the names of our relational design (EnergyProduction, Unit, Zone, Status, Weather, Date, Time). The physical flat table is `FlatTablePhysical`, because `FlatTable` is the name of the view.
- **Keys:** DateKey is the date as `yyyymmdd` and TimeKey is the hour; the other dimensions use identity keys. Weather key 0 is the "unknown" member for readings without weather.
- **Columnstore:** `CREATE CLUSTERED COLUMNSTORE INDEX ... ORDER (DateKey)` sorts the rows by date (SQL Server 2022 or newer). A rowgroup holds up to 1,048,576 rows, so with this sample the non-partitioned fact table is a single rowgroup and a date filter cannot skip any of it; the ordering pays off (segment elimination) once the table holds several rowgroups. In the partitioned variant, every year is its own partition, so date filters skip whole years (partition elimination).
- **CloudCover / SunshineDuration:** whole numbers stored as `DECIMAL(1,0)` / `DECIMAL(2,0)`, because `AVG()` of an integer column returns a truncated integer (a daily mean of 6.7 oktas would become 6 and the day would not be Cloudy). `AVG()` of a DECIMAL column returns at least 6 decimal places.
- **Partitions:** yearly, on `DateKey` (no extra date column is needed, unlike the template's `SaleDate`); 2024 holds 311,016 rows and 2025 354,816, both enough for compressed rowgroups. Unique indexes are aligned, so they include `DateKey`.
- **SCD2:** changed attributes get ValidFrom = 2025-01-01, the first day after the T1 readings (the sources keep no change date). Each reading points to the version valid at its time.
- **Flat table:** `OlderUnit` = age >= 5 whole years, which matches the 5-10 / over 10 age categories. `OldestWindTurbine` is flagged by UnitID, so all SCD2 versions keep the flag. The daily weather classes use one value per zone and hour, so they are not weighted by the number of units.
