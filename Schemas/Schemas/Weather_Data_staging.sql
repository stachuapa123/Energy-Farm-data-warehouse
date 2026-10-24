/* Optional: staging table mirroring Weather_Data.csv, for loading the flat
   file into SQL Server during ETL. The CSV itself is the source system;
   this table is not part of PowerMaster.

   Datetime is landed as text (ISO 8601 with 'T') and converted in the view
   with style 126, which is independent of the server language/DATEFORMAT. */

USE PowerMaster;
GO

IF OBJECT_ID(N'dbo.vWeather_Data', N'V') IS NOT NULL DROP VIEW dbo.vWeather_Data;
IF OBJECT_ID(N'dbo.Weather_Data_Stage', N'U') IS NOT NULL DROP TABLE dbo.Weather_Data_Stage;
GO

CREATE TABLE dbo.Weather_Data_Stage (
    [Datetime]        CHAR(19)      NOT NULL,   -- yyyy-MM-ddTHH:mm:ss, start of the hour, UTC
    ZoneID            INT           NOT NULL,   -- = Zone.ZoneID
    AvgTemperature    DECIMAL(4,1)  NOT NULL,   -- °C
    AvgWindSpeed      DECIMAL(4,1)  NOT NULL,   -- m/s at 10 m
    Precipitation     DECIMAL(5,1)  NOT NULL,   -- mm in the hour
    CloudCover        TINYINT       NOT NULL,   -- oktas 0-8
    SunshineDuration  TINYINT       NOT NULL,   -- minutes 0-60
    CONSTRAINT PK_Weather_Data_Stage PRIMARY KEY ([Datetime], ZoneID),
    CONSTRAINT CK_Weather_Cloud    CHECK (CloudCover BETWEEN 0 AND 8),
    CONSTRAINT CK_Weather_Sunshine CHECK (SunshineDuration BETWEEN 0 AND 60)
);
GO

CREATE VIEW dbo.vWeather_Data AS
SELECT CONVERT(DATETIME, [Datetime], 126) AS [Datetime],
       ZoneID, AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration
FROM dbo.Weather_Data_Stage;
GO

/* Bulk load (the path is resolved on the SQL Server machine) */
DECLARE @file NVARCHAR(400) = N'C:\EcoVolt\Data\T1\Weather\Weather_Data.csv';
EXEC (N'BULK INSERT dbo.Weather_Data_Stage FROM ''' + @file + N''' WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CHECK_CONSTRAINTS, TABLOCK);');
SELECT COUNT(*) AS WeatherRows FROM dbo.Weather_Data_Stage;
