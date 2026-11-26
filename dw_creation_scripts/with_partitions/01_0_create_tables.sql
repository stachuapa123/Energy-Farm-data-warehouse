-- Compared with without_partitions, EnergyProduction is created on PS_EnergyProduction_DateKey (DateKey).
-- EcoVolt Data Warehouse - relational design (MS SQL Server)
IF DB_ID(N'EcoVoltDW_Part') IS NULL
    CREATE DATABASE EcoVoltDW_Part;
GO

USE EcoVoltDW_Part;
GO

-- ===================== Dimension tables =====================

CREATE TABLE dbo.Unit (
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
    ValidTo                DATETIME          NOT NULL CONSTRAINT DF_Unit_ValidTo DEFAULT '99991231',
    IsCurrent              BIT               NOT NULL CONSTRAINT DF_Unit_IsCurrent DEFAULT 1,
    CONSTRAINT CK_Unit_UnitType CHECK (UnitType IN ('Wind','Solar')),
    CONSTRAINT CK_Unit_MaxPowerCapacity CHECK (MaxPowerCapacity > 0),
    CONSTRAINT CK_Unit_ExpectedLifespanYears CHECK (ExpectedLifespanYears > 0),
    CONSTRAINT CK_Unit_Valid CHECK (ValidFrom < ValidTo)
);
GO

CREATE TABLE dbo.Zone (
    ZoneKey      INT IDENTITY(1,1) NOT NULL,
    ZoneID       INT               NOT NULL,
    ZoneName     VARCHAR(15)       NOT NULL,
    AreaSizeSqm  INT               NOT NULL,
    ValidFrom    DATETIME          NOT NULL,
    ValidTo      DATETIME          NOT NULL CONSTRAINT DF_Zone_ValidTo DEFAULT '99991231',
    IsCurrent    BIT               NOT NULL CONSTRAINT DF_Zone_IsCurrent DEFAULT 1,
    CONSTRAINT CK_Zone_ZoneName CHECK (ZoneName IN ('Gdansk','Szczecin','Olsztyn','Bialystok',
                                                    'Bydgoszcz','Zielona Gora','Poznan','Warszawa')),
    CONSTRAINT CK_Zone_AreaSizeSqm CHECK (AreaSizeSqm > 0),
    CONSTRAINT CK_Zone_Valid CHECK (ValidFrom < ValidTo)
);
GO

CREATE TABLE dbo.Status (
    StatusKey          TINYINT IDENTITY(1,1) NOT NULL,
    OperationalStatus  VARCHAR(15)           NOT NULL,
    IsOperating        BIT                   NOT NULL,
    CONSTRAINT CK_Status_OperationalStatus CHECK (OperationalStatus IN ('Operating','Fault','Maintenance'))
);
GO

CREATE TABLE dbo.Weather (
    WeatherKey                SMALLINT IDENTITY(0,1) NOT NULL,
    AvgTemperatureCategory    VARCHAR(10)            NOT NULL,
    AvgWindSpeedCategory      VARCHAR(10)            NOT NULL,
    PrecipitationCategory     VARCHAR(10)            NOT NULL,
    CloudCoverCategory        VARCHAR(15)            NOT NULL,
    SunshineDurationCategory  VARCHAR(10)            NOT NULL,
    CONSTRAINT CK_Weather_AvgTemperatureCategory CHECK (AvgTemperatureCategory IN ('freezing','cold','moderate','warm','hot','unknown')),
    CONSTRAINT CK_Weather_AvgWindSpeedCategory CHECK (AvgWindSpeedCategory IN ('calm','light','moderate','strong','unknown')),
    CONSTRAINT CK_Weather_PrecipitationCategory CHECK (PrecipitationCategory IN ('none','light','moderate','heavy','unknown')),
    CONSTRAINT CK_Weather_CloudCoverCategory CHECK (CloudCoverCategory IN ('clear','partly cloudy','overcast','unknown')),
    CONSTRAINT CK_Weather_SunshineDurationCategory CHECK (SunshineDurationCategory IN ('none','low','medium','high','full','unknown'))
);
GO

CREATE TABLE dbo.[Date] (
    DateKey      INT          NOT NULL,
    [Date]       DATE         NOT NULL,
    [Year]       SMALLINT     NOT NULL,
    QuarterNo    TINYINT      NOT NULL,
    [Month]      VARCHAR(10)  NOT NULL,
    MonthNo      TINYINT      NOT NULL,
    DayOfWeek    VARCHAR(10)  NOT NULL,
    DayOfWeekNo  TINYINT      NOT NULL,
    Season       VARCHAR(6)   NOT NULL,
    CONSTRAINT CK_Date_Year CHECK ([Year] BETWEEN 1000 AND 9999),
    CONSTRAINT CK_Date_QuarterNo CHECK (QuarterNo BETWEEN 1 AND 4),
    CONSTRAINT CK_Date_Month CHECK ([Month] IN ('January','February','March','April','May','June',
                                                'July','August','September','October','November','December')),
    CONSTRAINT CK_Date_MonthNo CHECK (MonthNo BETWEEN 1 AND 12),
    CONSTRAINT CK_Date_DayOfWeek CHECK (DayOfWeek IN ('Monday','Tuesday','Wednesday','Thursday',
                                                      'Friday','Saturday','Sunday')),
    CONSTRAINT CK_Date_DayOfWeekNo CHECK (DayOfWeekNo BETWEEN 1 AND 7),
    CONSTRAINT CK_Date_Season CHECK (Season IN ('Winter','Spring','Summer','Autumn'))
);
GO

CREATE TABLE dbo.[Time] (
    TimeKey    TINYINT      NOT NULL,
    [Hour]     TINYINT      NOT NULL,
    TimeOfDay  VARCHAR(10)  NOT NULL,
    CONSTRAINT CK_Time_Hour CHECK ([Hour] BETWEEN 0 AND 23),
    CONSTRAINT CK_Time_TimeOfDay CHECK (TimeOfDay IN ('night','morning','afternoon','evening'))
);
GO

-- ===================== Fact tables =====================

CREATE TABLE dbo.EnergyProduction (
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
    -- Whole numbers, but DECIMAL: AVG() of an integer column returns a truncated integer.
    CloudCover          DECIMAL(1,0)         NULL,
    SunshineDuration    DECIMAL(2,0)         NULL,
    CONSTRAINT CK_EnergyProduction_EnergyProduced CHECK (EnergyProduced >= 0),
    CONSTRAINT CK_EnergyProduction_MaxPossibleEnergy CHECK (MaxPossibleEnergy > 0),
    CONSTRAINT CK_EnergyProduction_CloudCover CHECK (CloudCover BETWEEN 0 AND 8),
    CONSTRAINT CK_EnergyProduction_SunshineDuration CHECK (SunshineDuration BETWEEN 0 AND 60)
) ON PS_EnergyProduction_DateKey (DateKey);
GO
