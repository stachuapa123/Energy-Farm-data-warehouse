# Loading the EcoVolt data into SQL Server (Docker on Linux)

These steps run SQL Server 2022 in a Docker container on Linux (written for Fedora, works the same on other distributions), load the PowerMaster and Weather data, and let you query it from VS Code.

SQL Server runs **inside the container**, so all file paths used by the SQL scripts are paths inside the container (`/var/opt/mssql/import/...`), not paths on your own disk.

> **Using the repository `docker-compose.yml` instead:** `docker compose up -d` (from the repository root) starts SQL Server as container **`mssql-db`** with the same `sa` password as `docker-compose.yml`, so skip step 1 and use `mssql-db` wherever this guide says `sql1`. `./run.sh sources` runs steps 3, 4, 6 and 7 for snapshot T1. The data warehouse itself is described in `README.md`.

## 0. Before you start

Make sure the Docker service is running, and open a terminal in the project root (the folder that contains `Data`, `Schemas`, `Generator`).

```bash
sudo systemctl enable --now docker   # start Docker now and at every boot
docker version                       # should show a Client and a Server section
```

If `docker` says "permission denied", either prefix the commands with `sudo`, or add yourself to the docker group once and log out and in again:

```bash
sudo usermod -aG docker $USER
```

## 1. Start SQL Server (first time only)

```bash
docker run -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=Praca6767!!' \
  -p 1433:1433 --name sql1 \
  -v sqldata:/var/opt/mssql \
  --restart unless-stopped \
  -d mcr.microsoft.com/mssql/server:2022-latest
```

- Keep the **single quotes**. In double quotes bash expands `!!` into your previous command.
- The password must be at least 8 characters and contain 3 of 4: upper case, lower case, digits, symbols. A weak password makes the container stop immediately.
- `-v sqldata:/var/opt/mssql` keeps your databases even if the container is deleted.
- `--restart unless-stopped` starts the container again after a reboot, unless you stopped it yourself.

Check that it is up:

```bash
docker ps
docker logs sql1 --tail 5
```

Look for: `SQL Server is now ready for client connections`.

## 2. Connect from VS Code

1. Install the **SQL Server (mssql)** extension.
2. Add a connection with these settings:

| Field | Value |
|---|---|
| Server name | `localhost` (port `1433`) |
| Authentication type | SQL Login |
| User name | `sa` |
| Password | the one from step 1 |
| Trust server certificate | **ticked** |

## 3. Create the database

In VS Code, open `Schemas/PowerMaster_schema.sql`, make sure it is connected to the `localhost` connection, and run it (`Ctrl+Shift+E`).

## 4. Copy the data into the container

BULK INSERT reads files on the **SQL Server machine**, i.e. inside the container, so the CSV files must be copied in.

```bash
docker exec -u root sql1 mkdir -p /var/opt/mssql/import
docker cp Data/. sql1:/var/opt/mssql/import/
docker exec -u root sql1 chmod -R a+rX /var/opt/mssql/import
docker exec sql1 ls -R /var/opt/mssql/import/T1
```

What each line does:

| Command | Purpose |
|---|---|
| `mkdir -p` | creates the `import` folder inside the container |
| `docker cp Data/. ...` | copies the *contents* of `Data` into it (the trailing `.` matters) |
| `chmod -R a+rX` | lets the SQL Server user read the files |
| `ls -R` | lists the result so you can check it |

Expected: `PowerMaster` (5 CSV files) and `Weather` (`Weather_Data.csv`).

**Alternative (no copying):** share the folder when creating the container by adding this to the `docker run` command in step 1:

```bash
-v "$PWD/Data:/var/opt/mssql/import:ro,z"
```

The `z` is needed on Fedora, RHEL and other SELinux systems, otherwise the container cannot read the files. It relabels the `Data` folder for container access.

## 5. Check the line endings

The load scripts expect LF line endings (`0x0a`). Check that the files have no Windows (CRLF) endings:

```bash
grep -c $'\r' Data/T1/PowerMaster/Unit.csv
```

- `0`: fine, use the scripts as they are.
- Any other number: the file has CRLF. Either change `ROWTERMINATOR = ''0x0a''` to `ROWTERMINATOR = ''0x0d0a''` in the load scripts, or convert the files with `sed -i 's/\r$//' Data/T1/*/*.csv` (and the same for `T2`) and copy them again.

## 6. Load PowerMaster

Open `load_snapshot.sql` and make exactly these changes:

```sql
DECLARE @dir NVARCHAR(400) = N'/var/opt/mssql/import/T1/PowerMaster/';   -- T2: .../T2/PowerMaster/
```

and in `@opts` use `CODEPAGE = ''RAW''` instead of `''65001''` (SQL Server on Linux only supports `RAW`).

Run it. The last query returns the row count of each table; compare it with `manifest.json`.

## 7. Load Weather

Run `Weather_Data_staging_linux.sql` (path already set to `/var/opt/mssql/import/T1/Weather/Weather_Data.csv`; use `T2` for the T2 snapshot). It creates `dbo.Weather_Data_Stage` and the view `dbo.vWeather_Data`, loads the CSV and returns the row count. It drops and recreates its objects, so it is safe to re-run.

## 8. Query

```sql
USE PowerMaster;

SELECT TOP 20 * FROM dbo.ProductionLog;
SELECT TOP 20 * FROM dbo.vWeather_Data ORDER BY [Datetime];

-- list all tables and columns
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY TABLE_NAME, ORDINAL_POSITION;
```

## T1 to T2

Choose one:

- **Incremental:** with T1 loaded, run `Data/T2_delta/PowerMaster/apply_T2_delta.sql` (change any `C:\` paths in it to `/var/opt/mssql/import/...`).
- **From scratch:** drop the database, re-run the schema, and load with `@dir` set to the `T2` folder.

Do not bulk-load T2 on top of T1 (the IDs are identical and you will get primary key violations).

To start clean:

```sql
USE master;
DROP DATABASE PowerMaster;
```

## Everyday commands

```bash
docker ps                   # running containers
docker ps -a                # all containers, including stopped
docker stop sql1            # stop SQL Server
docker start sql1           # start it again
docker logs sql1 --tail 20  # last log lines
docker rm -f sql1           # delete the container (data survives if you used -v sqldata)
```

## Updating Docker (Fedora)

```bash
sudo dnf upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl restart docker
```

Restarting the daemon briefly stops your containers. `sql1` comes back by itself if it was created with `--restart unless-stopped`; otherwise run `docker start sql1`.

## Troubleshooting

| Problem | Likely cause and fix |
|---|---|
| Container shows `Exited` right after start | Weak `sa` password or missing `ACCEPT_EULA=Y`. Check `docker logs sql1`, then `docker rm sql1` and run step 1 again. |
| `Login failed for user 'sa'` | Password in VS Code differs from the one used in `docker run`. |
| Certificate error when connecting | Tick **Trust server certificate**. |
| `Cannot bulk load ... does not exist` (error code 2) | Wrong path or files not copied. Redo step 4 and check the trailing `/` in `@dir`. |
| `Operating system error code 5` / access denied | Re-run the `chmod` command in step 4. With a bind mount on Fedora, make sure you used `:z`. |
| `CODEPAGE ... not supported` | Use `CODEPAGE = ''RAW''` (step 6). |
| Conversion errors / unexpected end of file | CRLF line endings (step 5). |
| Duplicate key errors on reload | Part of the data was already loaded. Drop the database and start from step 3. |
| Port 1433 already in use | Another SQL Server is running. Stop it, or use `-p 1434:1433` and connect to `localhost,1434`. |
| `permission denied` running `docker` | Use `sudo`, or add yourself to the `docker` group (step 0). |