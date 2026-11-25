-- EcoVolt Data Warehouse - relational design (MS SQL Server)
-- Process: Energy Production Monitoring. Star schema: fact ENERGY_PRODUCTION,
-- dimensions UNIT (SCD2), ZONE (SCD2), STATUS, WEATHER (junk), DATE, TIME.
-- Primary keys, foreign keys and indexes are added after the bulk load (04_*.sql).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF DB_ID(N'EcoVoltDW') IS NULL
    CREATE DATABASE EcoVoltDW;
GO

USE EcoVoltDW;
GO

-- ===================== Dimension tables =====================

CREATE TABLE dbo.UNIT (
    UnitKey                INT IDENTITY(1,1) NOT NULL,
    UnitID                 VARCHAR(10)       NOT NULL,
    ManufacturerID         INT               NOT NULL,
    ManufacturerName       VARCHAR(50)       NOT NULL,
    ManufacturerCountry    VARCHAR(30)       NOT NULL,
    ModelID                INT               NOT NULL,
    ModelName              VARCHAR(50)       NOT NULL,
    UnitType               VARCHAR(20)       NOT NULL,
    MaxPowerCapacity       DECIMAL(8,2)      NOT NULL,
    InstallationDateTime   DATETIME          NOT NULL,
    ExpectedLifespanYears  INT               NOT NULL,
    ValidFrom              DATETIME          NOT NULL,
    ValidTo                DATETIME          NOT NULL CONSTRAINT DF_UNIT_ValidTo DEFAULT '99991231',
    IsCurrent              BIT               NOT NULL CONSTRAINT DF_UNIT_IsCurrent DEFAULT 1,
    CONSTRAINT CK_UNIT_UnitType CHECK (UnitType IN ('Wind','Solar')),
    CONSTRAINT CK_UNIT_MaxPowerCapacity CHECK (MaxPowerCapacity > 0),
    CONSTRAINT CK_UNIT_ExpectedLifespanYears CHECK (ExpectedLifespanYears > 0),
    CONSTRAINT CK_UNIT_Valid CHECK (ValidFrom < ValidTo)
);
GO

CREATE TABLE dbo.ZONE (
    ZoneKey      INT IDENTITY(1,1) NOT NULL,
    ZoneID       INT               NOT NULL,
    ZoneName     VARCHAR(15)       NOT NULL,
    AreaSizeSqm  INT               NOT NULL,
    ValidFrom    DATETIME          NOT NULL,
    ValidTo      DATETIME          NOT NULL CONSTRAINT DF_ZONE_ValidTo DEFAULT '99991231',
    IsCurrent    BIT               NOT NULL CONSTRAINT DF_ZONE_IsCurrent DEFAULT 1,
    CONSTRAINT CK_ZONE_ZoneName CHECK (ZoneName IN ('Gdansk','Szczecin','Olsztyn','Bialystok',
                                                    'Bydgoszcz','Zielona Gora','Poznan','Warszawa')),
    CONSTRAINT CK_ZONE_AreaSizeSqm CHECK (AreaSizeSqm > 0),
    CONSTRAINT CK_ZONE_Valid CHECK (ValidFrom < ValidTo)
);
GO

CREATE TABLE dbo.STATUS (
    StatusKey          TINYINT IDENTITY(1,1) NOT NULL,
    OperationalStatus  VARCHAR(15)           NOT NULL,
    IsOperating        BIT                   NOT NULL,
    CONSTRAINT CK_STATUS_OperationalStatus CHECK (OperationalStatus IN ('Operating','Fault','Maintenance'))
);
GO

-- Junk dimension: all combinations of the weather categories (5 x 4 x 4 x 3 x 5 = 1200)
-- plus the "unknown" member with WeatherKey = 0 (inserted first, IDENTITY starts at 0).
CREATE TABLE dbo.WEATHER (
    WeatherKey                SMALLINT IDENTITY(0,1) NOT NULL,
    AvgTemperatureCategory    VARCHAR(10)            NOT NULL,
    AvgWindSpeedCategory      VARCHAR(10)            NOT NULL,
    PrecipitationCategory     VARCHAR(10)            NOT NULL,
    CloudCoverCategory        VARCHAR(15)            NOT NULL,
    SunshineDurationCategory  VARCHAR(10)            NOT NULL,
    CONSTRAINT CK_WEATHER_AvgTemperatureCategory CHECK (AvgTemperatureCategory IN ('freezing','cold','moderate','warm','hot','unknown')),
    CONSTRAINT CK_WEATHER_AvgWindSpeedCategory CHECK (AvgWindSpeedCategory IN ('calm','light','moderate','strong','unknown')),
    CONSTRAINT CK_WEATHER_PrecipitationCategory CHECK (PrecipitationCategory IN ('none','light','moderate','heavy','unknown')),
    CONSTRAINT CK_WEATHER_CloudCoverCategory CHECK (CloudCoverCategory IN ('clear','partly cloudy','overcast','unknown')),
    CONSTRAINT CK_WEATHER_SunshineDurationCategory CHECK (SunshineDurationCategory IN ('none','low','medium','high','full','unknown'))
);
GO

CREATE TABLE dbo.[DATE] (
    DateKey      INT          NOT NULL,   -- yyyymmdd
    [Date]       DATE         NOT NULL,
    [Year]       SMALLINT     NOT NULL,
    QuarterNo    TINYINT      NOT NULL,
    [Month]      VARCHAR(10)  NOT NULL,
    MonthNo      TINYINT      NOT NULL,
    DayOfWeek    VARCHAR(10)  NOT NULL,
    DayOfWeekNo  TINYINT      NOT NULL,
    Season       VARCHAR(6)   NOT NULL,
    CONSTRAINT CK_DATE_Year CHECK ([Year] BETWEEN 1000 AND 9999),
    CONSTRAINT CK_DATE_QuarterNo CHECK (QuarterNo BETWEEN 1 AND 4),
    CONSTRAINT CK_DATE_Month CHECK ([Month] IN ('January','February','March','April','May','June',
                                                'July','August','September','October','November','December')),
    CONSTRAINT CK_DATE_MonthNo CHECK (MonthNo BETWEEN 1 AND 12),
    CONSTRAINT CK_DATE_DayOfWeek CHECK (DayOfWeek IN ('Monday','Tuesday','Wednesday','Thursday',
                                                      'Friday','Saturday','Sunday')),
    CONSTRAINT CK_DATE_DayOfWeekNo CHECK (DayOfWeekNo BETWEEN 1 AND 7),
    CONSTRAINT CK_DATE_Season CHECK (Season IN ('Winter','Spring','Summer','Autumn'))
);
GO

CREATE TABLE dbo.[TIME] (
    TimeKey    TINYINT      NOT NULL,   -- = Hour
    [Hour]     TINYINT      NOT NULL,
    TimeOfDay  VARCHAR(10)  NOT NULL,
    CONSTRAINT CK_TIME_Hour CHECK ([Hour] BETWEEN 0 AND 23),
    CONSTRAINT CK_TIME_TimeOfDay CHECK (TimeOfDay IN ('night','morning','afternoon','evening'))
);
GO

-- ===================== Fact tables =====================

CREATE TABLE dbo.ENERGY_PRODUCTION (
    EnergyProductionID  BIGINT IDENTITY(1,1) NOT NULL,
    DateKey             INT                  NOT NULL,
    TimeKey             TINYINT              NOT NULL,
    UnitKey             INT                  NOT NULL,
    ZoneKey             INT                  NOT NULL,
    StatusKey           TINYINT              NOT NULL,
    WeatherKey          SMALLINT             NOT NULL,
    ProductionLogID     INT                  NOT NULL,
    EnergyProduced      DECIMAL(10,3)        NOT NULL,
    MaxPossibleEnergy   DECIMAL(10,3)        NOT NULL,
    AvgTemperature      DECIMAL(5,2)         NULL,
    AvgWindSpeed        DECIMAL(5,2)         NULL,
    Precipitation       DECIMAL(6,2)         NULL,
    -- DECIMAL (not INT) so that AVG() is not truncated to an integer.
    CloudCover          DECIMAL(4,2)         NULL,
    SunshineDuration    DECIMAL(4,1)         NULL,
    CONSTRAINT CK_ENERGY_PRODUCTION_EnergyProduced CHECK (EnergyProduced >= 0),
    CONSTRAINT CK_ENERGY_PRODUCTION_MaxPossibleEnergy CHECK (MaxPossibleEnergy > 0),
    CONSTRAINT CK_ENERGY_PRODUCTION_CloudCover CHECK (CloudCover BETWEEN 0 AND 8),
    CONSTRAINT CK_ENERGY_PRODUCTION_SunshineDuration CHECK (SunshineDuration BETWEEN 0 AND 60)
);
GO
