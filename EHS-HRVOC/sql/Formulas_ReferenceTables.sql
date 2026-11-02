/* ============================================================================
   Emissions Calculations — "Formulas" sheet  ->  SQL reference tables
   Source workbook : EmissionsCalculations_claude_v2.xlsm  (sheet "Formulas")
   Target          : Microsoft SQL Server (T-SQL)
   Purpose         : Replace the Excel "Formulas" constants sheet with reference
                     tables so the emission math can run in SQL / SSRS.

   Every INSERT is commented with the originating Formulas!<cell>.
   Numeric columns use FLOAT to match Excel's double-precision arithmetic
   (important for the cubic molecular-weight curve fits).

   Re-runnable: drops and recreates the ref.* tables and the helper function.
   ============================================================================ */

SET NOCOUNT ON;
GO

IF SCHEMA_ID('ref') IS NULL
    EXEC ('CREATE SCHEMA ref AUTHORIZATION dbo;');
GO

/* Drop in dependency order (function first) ------------------------------- */
IF OBJECT_ID('ref.ufnEmissionFactor','FN')  IS NOT NULL DROP FUNCTION ref.ufnEmissionFactor;
IF OBJECT_ID('ref.OxidizerBand','U')         IS NOT NULL DROP TABLE ref.OxidizerBand;
IF OBJECT_ID('ref.MwCurveFit','U')           IS NOT NULL DROP TABLE ref.MwCurveFit;
IF OBJECT_ID('ref.Compound','U')             IS NOT NULL DROP TABLE ref.Compound;
IF OBJECT_ID('ref.FlareTip','U')             IS NOT NULL DROP TABLE ref.FlareTip;
IF OBJECT_ID('ref.FlareStream','U')          IS NOT NULL DROP TABLE ref.FlareStream;
IF OBJECT_ID('ref.ProcessConstant','U')      IS NOT NULL DROP TABLE ref.ProcessConstant;
GO

/* =========================================================================
   1. ref.Compound  — per-compound physical constants
      Formulas!  MW: B10-B12 | SCFM->lb/hr: B15-B17 | BTU/SCF: B20-B23
   ========================================================================= */
CREATE TABLE ref.Compound (
    CompoundCode      varchar(4)   NOT NULL PRIMARY KEY,  -- BD, BU, PR, NG
    CompoundName      varchar(30)  NOT NULL,
    MolecularWeight   float        NULL,   -- lb/lb-mole
    ScfmToLbHrFactor  float        NULL,   -- SCFM -> lb/hr  (= MW / 379 * 60)
    BtuPerScf         float        NULL    -- heat release, BTU/SCF
);
GO
INSERT INTO ref.Compound (CompoundCode, CompoundName, MolecularWeight, ScfmToLbHrFactor, BtuPerScf) VALUES
    ('BD','Butadiene',       54.1, 8.5488, 2689),  -- MW B10 | conv B15 | BTU B20
    ('BU','Butylene (Butene)',56.1, 8.8650, 2879), -- MW B11 | conv B16 | BTU B21
    ('PR','Propylene',       42.1, 6.6491, 2182),  -- MW B12 | conv B17 | BTU B22
    ('NG','Natural Gas',     NULL, NULL,   1000);  -- BTU B23 (no MW / conversion used)
GO

/* =========================================================================
   2. ref.MwCurveFit  — cubic fit:  MWact = Cube*r^3 + Sq*r^2 + Lin*r + Const
      Formulas!  BD D27-D30 | BU D32-D35 | PR D37-D40
      (full-precision coefficients per the documented equations in A2/A4/A6)
   ========================================================================= */
CREATE TABLE ref.MwCurveFit (
    CompoundCode  varchar(4) NOT NULL PRIMARY KEY
        REFERENCES ref.Compound(CompoundCode),
    ConstTerm     float NOT NULL,   -- Formulas D27 / D32 / D37
    LinearCoef    float NOT NULL,   -- Formulas D28 / D33 / D38  (coef of r^1)
    SquareCoef    float NOT NULL,   -- Formulas D29 / D34 / D39  (coef of r^2)
    CubeCoef      float NOT NULL    -- Formulas D30 / D35 / D40  (coef of r^3)
);
GO
INSERT INTO ref.MwCurveFit (CompoundCode, ConstTerm, LinearCoef, SquareCoef, CubeCoef) VALUES
    ('BD', 15.9578272,  0.1631686,  0.0161899, -0.0001178),  -- Formulas D27-D30
    ('BU', 17.3511524,  0.0829741,  0.0170495, -0.0001140),  -- Formulas D32-D35
    ('PR', 21.5654934, -0.2722180,  0.0270375, -0.0002159);  -- Formulas D37-D40
GO

/* =========================================================================
   3. ref.OxidizerBand — temperature-banded emission factors (TO-A / TO-B)
      Formulas!  TO-A rows 43-48 | TO-B rows 51-56
      Columns: D=Low limit, E=High limit, F=NOx lb/MMBtu, G=CO lb/MMBtu,
               H=% destruction efficiency (BD)
      LOOKUP SEMANTICS (matches the Excel IF-ladder, e.g. HRVOC col L/Y/AN):
         pick the band with the greatest LowLimitF such that  temp > LowLimitF;
         if temp is at/below the lowest limit, the lowest band applies.
      The sheet's "FLARE" rows (49 / 57) are NOT bands; they live in
      ref.ProcessConstant (FlareNOx / FlareCO / ...).
   ========================================================================= */
CREATE TABLE ref.OxidizerBand (
    Oxidizer        varchar(4) NOT NULL,     -- 'TO-A' | 'TO-B'
    BandSeq         tinyint    NOT NULL,     -- 1..6, increasing temperature
    LowLimitF       float      NOT NULL,     -- Formulas col D  (lookup threshold)
    HighLimitF      float      NULL,         -- Formulas col E  (reference only; top band open-ended)
    NOxLbPerMMBtu   float      NOT NULL,     -- Formulas col F
    COLbPerMMBtu    float      NOT NULL,     -- Formulas col G
    DestructionEff  float      NOT NULL,     -- Formulas col H  (% efficiency BD)
    CONSTRAINT PK_OxidizerBand PRIMARY KEY (Oxidizer, BandSeq)
);
GO
INSERT INTO ref.OxidizerBand (Oxidizer, BandSeq, LowLimitF, HighLimitF, NOxLbPerMMBtu, COLbPerMMBtu, DestructionEff) VALUES
    -- TO-A : Formulas rows 43-48
    ('TO-A', 1,    0.0,  800.0, 0.101, 0.028, 0.07),     -- row43
    ('TO-A', 2,  800.1, 1000.0, 0.140, 0.175, 0.00005),  -- row44  (TO-A min operating temp 800.1)
    ('TO-A', 3, 1001.0, 1414.6, 0.225, 0.089, 0.00004),  -- row45
    ('TO-A', 4, 1414.6, 1572.3, 0.085, 0.033, 0.0002),   -- row46
    ('TO-A', 5, 1572.4, 1820.5, 0.118, 0.082, 0.0001),   -- row47
    ('TO-A', 6, 1820.6, NULL,   0.150, 0.0004, 0.0001),  -- row48  (open-ended top band)
    -- TO-B : Formulas rows 51-56
    ('TO-B', 1,    0.0,  800.0, 0.101, 0.028, 0.07),     -- row51
    ('TO-B', 2,  800.1, 1000.0, 0.139, 0.168, 0.00004),  -- row52  (TO-B min operating temp 800.1)
    ('TO-B', 3, 1000.1, 1377.3, 0.171, 0.043, 0.00003),  -- row53
    ('TO-B', 4, 1377.4, 1600.0, 0.101, 0.028, 0.0006),   -- row54
    ('TO-B', 5, 1600.1, 2204.0, 0.105, 0.023, 0.0002),   -- row55
    ('TO-B', 6, 2204.1, NULL,   0.169, 0.001, 0.0001);   -- row56  (open-ended top band)
GO

/* =========================================================================
   4. ref.ProcessConstant — loose scalar constants on the Formulas sheet
   ========================================================================= */
CREATE TABLE ref.ProcessConstant (
    ConstantKey    varchar(40) NOT NULL PRIMARY KEY,
    ConstantValue  float       NOT NULL,
    Description    varchar(80) NOT NULL,
    SourceCell     varchar(12) NOT NULL
);
GO
INSERT INTO ref.ProcessConstant (ConstantKey, ConstantValue, Description, SourceCell) VALUES
    ('MwCheckpoint',        29.0,    'MW floor: if MWact < this, use 28 (~N2)',        'B76'),
    ('FlareEff_F035_12',    0.02,    'F035_12 flare efficiency (fraction)',            'B72'),
    ('FlareEff_F105_03',    0.02,    'F105_03 flare efficiency (fraction)',            'B73'),
    ('FlareCO_LbPerMMBtu',  0.02755, 'Flare CO factor (lb CO / MMBtu)',                'B74'),
    ('FlareNOx_LbPerMMBtu', 0.138,   'Flare NOx factor (lb NOx / MMBtu)',              'B75'),
    ('TOA_MinOperTempF',    800.1,   'TO-A minimum operating temperature (deg F)',     'D44'),
    ('TOB_MinOperTempF',    800.1,   'TO-B minimum operating temperature (deg F)',     'D52');
GO

/* =========================================================================
   5. ref.FlareTip — flare tip geometry & velocity reference
      Formulas rows 66-71 (A=Flare, B=Product, C=TipArea, D=HeatRelease,
      E=Vmax, F=Fmax). Vmax/Fmax are derived in the sheet:
         Vmax(ft/s) = (8.706 + HeatRelease*0.037) * 3.281
         Fmax(SCFM) = Vmax * TipArea * 60
      Stored as-is for reference.
   ========================================================================= */
CREATE TABLE ref.FlareTip (
    FlareCode          varchar(8)  NOT NULL PRIMARY KEY,  -- HRVOC, 50-2, 105-1, 105-2, 105-3, 35-12
    Product            varchar(20) NOT NULL,
    TipAreaFt2         float       NOT NULL,   -- Formulas col C
    HeatReleaseBtuScf  float       NOT NULL,   -- Formulas col D
    VmaxFtSec          float       NOT NULL,   -- Formulas col E (derived)
    FmaxScfm           float       NOT NULL    -- Formulas col F (derived)
);
GO
INSERT INTO ref.FlareTip (FlareCode, Product, TipAreaFt2, HeatReleaseBtuScf, VmaxFtSec, FmaxScfm) VALUES
    ('HRVOC','Butadiene', 0.119, 2689, 355.000919, 2534.706562),  -- row66
    ('50-2', 'Butadiene', 0.119, 2689, 355.000919, 2534.706562),  -- row67
    ('105-1','Propylene', 0.299, 2182, 293.452640, 5264.540362),  -- row68
    ('105-2','Propylene', 0.299, 2182, 293.452640, 5264.540362),  -- row69
    ('105-3','Butadiene', 0.333, 2689, 355.000919, 7092.918362),  -- row70
    ('35-12','Butene',    0.101, 2879, 378.066349, 2291.082075);  -- row71
GO

/* =========================================================================
   6. ref.FlareStream — which compound each flare-gas stream's CALCULATION uses
      Derived from the calculation sheets (not the Formulas sheet):
        HRVOC, 50-2, 105-01/02/03  -> Butadiene (D27-D30, B15, B20)
        35-12                      -> Butene    (D32-D35, B16, B21)
      NOTE: ref.FlareTip labels 105-1 / 105-2 as Propylene, but the
      "105-0x Flare Calculations" sheets actually compute them with the
      Butadiene coefficients. Flagged for reconciliation; this table reflects
      what the calculations do today. Change to 'PR' if Propylene is intended.
   ========================================================================= */
CREATE TABLE ref.FlareStream (
    FlareCode     varchar(8) NOT NULL PRIMARY KEY,
    CompoundCode  varchar(4) NOT NULL REFERENCES ref.Compound(CompoundCode),
    FlareEffKey   varchar(40) NULL   -- optional link into ref.ProcessConstant
);
GO
INSERT INTO ref.FlareStream (FlareCode, CompoundCode, FlareEffKey) VALUES
    ('HRVOC','BD', NULL),
    ('50-2', 'BD', NULL),
    ('35-12','BU', 'FlareEff_F035_12'),
    ('105-1','BD', NULL),
    ('105-2','BD', NULL),
    ('105-3','BD', 'FlareEff_F105_03');
GO

/* =========================================================================
   7. ref.ufnEmissionFactor — optional helper replicating the Excel IF-ladder
      Returns the banded factor for an oxidizer at a given temperature.
      @FactorType : 'NOX' | 'CO' | 'EFF'
      Example:  SELECT ref.ufnEmissionFactor('TO-A', 1650, 'CO');  -> 0.082
   ========================================================================= */
GO
CREATE FUNCTION ref.ufnEmissionFactor
(
    @Oxidizer   varchar(4),
    @TempF      float,
    @FactorType varchar(3)
)
RETURNS float
AS
BEGIN
    DECLARE @v float;

    ;WITH band AS (
        SELECT TOP (1)
               NOxLbPerMMBtu, COLbPerMMBtu, DestructionEff
        FROM   ref.OxidizerBand
        WHERE  Oxidizer = @Oxidizer
          AND  @TempF > LowLimitF
        ORDER BY LowLimitF DESC
    )
    SELECT @v = CASE @FactorType
                    WHEN 'NOX' THEN NOxLbPerMMBtu
                    WHEN 'CO'  THEN COLbPerMMBtu
                    WHEN 'EFF' THEN DestructionEff
                END
    FROM band;

    -- Excel's final ELSE returns the lowest band (BandSeq = 1) when temp is
    -- at/below the lowest limit and no band qualifies.
    IF @v IS NULL
        SELECT @v = CASE @FactorType
                        WHEN 'NOX' THEN NOxLbPerMMBtu
                        WHEN 'CO'  THEN COLbPerMMBtu
                        WHEN 'EFF' THEN DestructionEff
                    END
        FROM ref.OxidizerBand
        WHERE Oxidizer = @Oxidizer AND BandSeq = 1;

    RETURN @v;
END;
GO

/* ---- quick verification -------------------------------------------------
SELECT * FROM ref.Compound;
SELECT * FROM ref.MwCurveFit;
SELECT * FROM ref.OxidizerBand ORDER BY Oxidizer, BandSeq;
SELECT * FROM ref.ProcessConstant;
SELECT * FROM ref.FlareTip;
SELECT * FROM ref.FlareStream;
-- Band lookup spot-checks (compare against the Excel IF-ladder):
SELECT ref.ufnEmissionFactor('TO-A',  700, 'CO')  AS toa_700_co,    -- 0.028  (band1)
       ref.ufnEmissionFactor('TO-A', 1650, 'CO')  AS toa_1650_co,   -- 0.082  (band5)
       ref.ufnEmissionFactor('TO-B', 2300, 'NOX') AS tob_2300_nox,  -- 0.169  (band6)
       ref.ufnEmissionFactor('TO-A', 1900, 'EFF') AS toa_1900_eff;  -- 0.0001 (band6)
--------------------------------------------------------------------------- */
