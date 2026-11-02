# Emissions Calculations Workbook — Technical Documentation

**Reference version:** `EmissionsCalculations_claude_v2.xlsm`
**Owner:** ITC (Intercontinental Terminals Company) — HRVOC emissions reporting
**Documented:** 2026-10-31

---

## 1. Purpose

This macro-enabled workbook produces **daily and monthly air-emissions reports** (CO and NOx)
for ITC's flares and thermal oxidizers, for HRVOC (Highly Reactive Volatile Organic Compound)
regulatory reporting. It:

1. Pulls one day of per-minute process data from a SQL Server database over ODBC,
2. Runs combustion-emission calculations on that data in worksheet formulas,
3. Rolls the results up into summary sheets, and
4. Exports the summary as an Excel file and/or PDF, optionally emailing it.

The emission sources covered are the **HRVOC flare**, the **50-2 flare**, the **35-12 flare**,
the **105-01/02/03 flares**, and the two **thermal oxidizers TO-A and TO-B** that the flare gas
can be routed to, plus **natural gas** combustion at the oxidizers.

---

## 2. Architecture & data flow

```
 SQL Server  (database: Reports15min)
   per-minute process tags per source table
          │   8 × QueryTables.Add  (ODBC, filtered to ONE calendar day)
          ▼
 Raw landing sheets:  TO_A  TO_B  HRVOC_FLARE  F050_02  F035_12  F105_01  F105_02  F105_03
   (and *_CSI companion landing sheets)
          │   referenced by
          ▼
 "Raw Data"  sheet  ──►  Calculation sheets:
          │                 • HRVOC to TOs Flare Calculations
          │                 • 50-2 to TOs Flare Calculations
          │                 • Natural Gas CO & NOx Emissions
          │                 • 35-12 Flare Calculations
          │                 • 105-01 / 105-02 / 105-03 Flare Calculations
          │                 (constants pulled from the "Formulas" sheet)
          ▼
 Summary / Summary (2) / Summary Others / SummaryGraph
          │
          ▼
 Output:  .xlsx (SaveXL)   ·   .pdf (SavePDF)   ·   Outlook email (EmailPDF)
```

Connection, date selection, and file-naming are all driven by small configuration sheets
(**Settings**, **DateSelection**, **Variables**).

---

## 3. SQL data source & connection

### 3.1 Connection configuration (Settings sheet)

Connections are **DSN-less ODBC**, built at run time from the **Settings** worksheet. The value
cells are exposed as workbook-scoped named ranges and read by the VBA helper `DBConnection()`.

| Setting (named range) | Cell | Default | Purpose |
|---|---|---|---|
| Server (`SQL_Server`) | B3 | `SQL1` *(placeholder)* | SQL Server host or `host\instance` |
| Database (`SQL_Database`) | B4 | `Reports15min` | Target database |
| Authentication (`SQL_Auth`) | B5 | `Integrated` | `Integrated` (trusted) or `SQL` — dropdown |
| ODBC Driver (`SQL_Driver`) | B6 | `ODBC Driver 17 for SQL Server` | Must be installed on the PC — dropdown |
| Username (`SQL_User`) | B7 | *(blank)* | SQL auth only |
| Password (`SQL_Password`) | B8 | *(blank)* | SQL auth only |

`DBConnection()` returns, for integrated auth:

```
ODBC;DRIVER={<driver>};SERVER=<server>;DATABASE=<database>;Trusted_Connection=Yes;
```

and for SQL auth it substitutes `UID=<user>;PWD=<password>;` for `Trusted_Connection=Yes;`.

All 24 `QueryTables.Add` calls across the job modules pass `DBConnection()` as their connection
string, so the connection is defined in exactly one place.

### 3.2 Source tables and columns

Each source table is queried for a **single calendar day**, filtered by
`WHERE CONVERT(CHAR(10), TimeStamp, 120) = '<StartDate>'  ORDER BY TimeStamp`
(`StartDate` in `YYYY-MM-DD` form). The columns pulled per table:

| Table | Columns pulled | Lands on |
|---|---|---|
| `TO_A` | MOL_WT_HRVOC, SCFM_HRVOC, MOL_WT_50_2, SCFM_50_2, CTRL_TEMP, SCFM_GAS, PCV_GAS_PCT, MOV_100A, MOV_200A, MOV_300A, MOV_800A, TimeStamp | TO_A_CSI |
| `TO_B` | MOL_WT_HRVOC, SCFM_HRVOC, MOL_WT_50_2, SCFM_50_2, CTRL_TEMP, PCV_GAS_PCT, MOV_100A, MOV_200A, MOV_300A, MOV_800A, TimeStamp | TO_B_CSI |
| `HRVOC_FLARE` | MOL_WT, SCFM, PILOT_1, PILOT_2, PILOT_3, TOTAL_PILOTS, MOV_INLET, TimeStamp | HRVOC_FLARE_CSI |
| `F050_02` | SCFM, MOL_WT, PILOT_1, PILOT_2, TOTAL_PILOTS, MOV_INLET, TimeStamp | F050_02_CSI |
| `F035_12` | MOL_WT, SCFM, PILOT_1, PILOT_2, TOTAL_PILOTS, TimeStamp | F035_12_CSI |
| `F105_01` | MOL_WT, SCFM, PILOT_1, PILOT_2, TOTAL_PILOTS, TimeStamp | F105_01 |
| `F105_02` | MOL_WT, SCFM, PILOT_1, PILOT_2, TOTAL_PILOTS, TimeStamp | F105_02 |
| `F105_03` | MOL_WT, SCFM, PILOT_1, PILOT_2, TOTAL_PILOTS, TimeStamp | F105_03 |

Legend: **MOL_WT** = molecular weight from the flare-gas meter; **SCFM** = volumetric flow;
**CTRL_TEMP** = thermal-oxidizer temperature; **MOV_*** = routing-valve positions used to split
flow between TO-A / TO-B / flare; **PCV_GAS_PCT** / **SCFM_GAS** = natural-gas valve % open and flow;
**PILOT_* / TOTAL_PILOTS** = flare pilot flows.

---

## 4. Calculation methodology

The physics is identical for every flare-gas stream; only the product (and therefore the
constants) differs. All constants live on the **Formulas** sheet. The per-minute rows run down
each calculation sheet (≈ rows 4–1443, one per minute of the day); row 1 holds the daily totals.

### 4.1 Reactive-compound mass flow

1. **Actual molecular weight** from a cubic curve-fit of the meter reading `MWread`:

   `MWact = C·MWread³ + B·MWread² + A·MWread + Const`

   | Product | Const | A | B | C | (Formulas cells) |
   |---|---|---|---|---|---|
   | Butadiene (BD) | 15.9578 | 0.16317 | 0.016190 | −0.0001178 | D27–D30 |
   | Butene (BU) | 17.3512 | 0.082974 | 0.017049 | −0.000114 | D32–D35 |
   | Propylene (PR) | 21.5655 | −0.272218 | 0.027037 | −0.0002159 | D37–D40 |

   A floor is applied: if `MWact < 29` (checkpoint, B76) use **28** (≈ pure N₂).

2. **Reactive fraction** `X = (MWact − 28) / 26` for BD/BU (28 = MW of N₂; 26 = MW_BD − MW_N₂).
   Propylene uses `/14`.

3. **Mass flow (lb/hr)** `= k · X · SCFM`, where `k` converts SCFM→lb/hr (= MW ÷ 379 SCF/lb-mole × 60):
   **Butadiene 8.5488, Butene 8.865, Propylene 6.6491** (Formulas B15–B17).

### 4.2 Flow routing to TO-A / TO-B / flare

The share of flare gas sent to each destination is the valve position over the sum of valves,
e.g. `fraction_to_TO-A = MOV_100A / (MOV_100A + MOV_200A + MOV_300A)` (guarded against divide-by-zero).
Mass/heat to each destination = total × that fraction.

### 4.3 Heat input

`MMBtu/hr = (SCFM_routed · HeatRelease · 60) / 1,000,000`

Heat-release values (BTU/SCF, Formulas B20–B23): **Butadiene 2689, Butene 2879, Propylene 2182,
Natural Gas 1000.**

### 4.4 Emission factors (temperature-banded)

NOx, CO and destruction-efficiency factors are selected by the oxidizer temperature via a stepwise
`IF` ladder against temperature bands on the Formulas sheet:

- **TO-A** bands: rows D43–D48 (0 → 1820+ °F); columns **F = NOx lb/MMBtu, G = CO lb/MMBtu, H = % efficiency**.
- **TO-B** bands: rows D51–D56 (0 → 2204+ °F); same column meanings.
- **Flare** (direct, no oxidizer): fixed **NOx 0.138, CO 0.02755** (B75 / B74); 35-12 and 105-03 flare
  efficiency = **0.02** (B72 / B73).

### 4.5 Emissions and daily totals

`Emission (lb/hr) = factor (lb/MMBtu) · MMBtu/hr`

Row-1 daily totals integrate the per-minute rate: `= SUM(rate rows) / 60` (lb/hr sampled each
minute ÷ 60 = lb accumulated), some columns using `SUMIF(range,"<>#N/A")/60` to skip gaps.

### 4.6 Natural-gas split (Natural Gas CO & NOx sheet)

A base **40 SCFM** is split evenly (20 SCFM each) across the two oxidizer gas valves; any flow above
40 is split in proportion to valve openings:

`Fng→TO-A = 20 + (X − 40)·A/(A+B)`, `Fng→TO-B = 20 + (X − 40)·B/(A+B)` (floored at 0),
where `X` = natural-gas SCFM and `A`,`B` are the two valve % openings. Then
`MMBtu/hr = SCFM·1000·60/1e6`, times the temperature-banded CO/NOx factors.

### 4.7 Flare efficiency / tip velocity (reference block, Formulas rows 59–71)

`Vmax(ft/s) = (8.706 + HeatRelease·0.037) · 3.281`; if flare-tip velocity < Vmax the flare is
treated as 98 % efficient (99 % for propylene), otherwise 93 %. `Fmax (SCFM)` is tabulated per
flare tip area (HRVOC 0.119 ft², 50-2 0.119, 105-1/2 0.299, 105-3 0.333, 35-12 0.101 ft²).

---

## 5. VBA module reference

| Module | Role |
|---|---|
| **ThisWorkbook** | `Workbook_Open`: sizes the app window, selects DateSelection, stamps every sheet's page header ("Intercontinental Terminals Company") and footer (username + date). Contains a commented-out auto-run hook driven by the `EmRepAutorun` environment variable. `Workbook_BeforeClose`: clears the raw landing columns (TO_A, TO_B, HRVOC_FLARE, F035_12) and marks the book saved. |
| **DailyJob** | Main daily driver. Reads the selected date from `Variables` (F17/F18/F19), clears landing sheets, sets calc to manual, runs the 8 ODBC `QueryTables` for that day, recalculates, then copies the report sheets into a new workbook as values and saves. |
| **DailyImport** | Lighter import routine (6 queries); reads dates from `DateSelection` (B7/B8/C4). |
| **MonthlyJob** | Monthly variant; queries use fully-qualified `[Reports15min].[dbo].[table]` names. |
| **SaveXL** | Copies the report sheets to a new workbook, pastes values (Raw Data, F035_12, F105_03), and prompts `GetSaveAsFilename` to save an `.xlsx`. Save folder from `Variables!U2`, default name from `Variables!G2`. |
| **SavePDF** | Builds `Emissions-YYYY-MM-DD` from `Variables` F5/F7/F9 and exports the Summary sheets to PDF. |
| **EmailPDF** | Exports the Summary sheets to a PDF in `%TEMP%`, creates an Outlook mail with the PDF attached and displays it. |
| **HideCalcs** | Hides the calculation + Formulas sheets. |
| **Functions** | `Username()` (Windows user); `DBConnection()` (DSN-less ODBC string builder, see §3.1); `SettingVal()` (reads a named range from Settings). |
| **SleepVBA** | `Application.Wait`-based pause, `Seconds` optional (default 2). Replaces the former `kernel32` `Sleep` declare so it compiles on 32-bit and 64-bit Office. |
| **GetEnv** | Debug helper — message-boxes the `EmRepAutorun` env var. |
| **MsgNotImplemented** | Stub — "Coming Soon". |
| Sheet code modules | One per worksheet; no custom logic beyond Excel defaults. |

Each `QueryTables.Add` uses `.BackgroundQuery = False` on refresh, `FieldNames = True`,
`RefreshStyle = xlInsertDeleteCells`.

---

## 6. Configuration sheets

### DateSelection (user picks the report day)
Month / Day / Year entry (B4/C4/D4) is assembled into `B7 = YYYY-MM-DD` (the per-day SQL filter)
and `D7/B8 = YYYY-MM` (used for the monthly save folder).

### Variables (derived values & lookups)
- `F17/F18/F19` = year / month / day used by `DailyJob`; `F5/F7/F9` = month / day / year used by `SavePDF`.
- `G2` = report file name (`Emissions-YYYY-MM-DD.xlsx`); `U2` = save path (e.g. `C:\CSIReports\YYYY-MM`).
- Columns B/C/D = month-name/number/day lookup lists; H–S = 15-minute time-slot tables; `U4/U5/U7/U8`
  hold email list / owner placeholders used by the email path.

### Formulas (engineering constants)
Molecular weights, SCFM→lb/hr conversion factors, BTU/SCF heat-release values, the three cubic
MW curve-fit coefficient sets, the TO-A/TO-B temperature-band emission-factor tables, and the flare
efficiency / tip-velocity reference tables (all cited in §4).

---

## 7. Report outputs

- **Excel**: `SaveXL` → `C:\CSIReports\<YYYY-MM>\Emissions-<YYYY-MM-DD>.xlsx` (summary + supporting
  sheets, values only).
- **PDF**: `SavePDF` → Summary sheets to `Emissions-<YYYY-MM-DD>.pdf`.
- **Email**: `EmailPDF` → PDF of the summaries attached to a new Outlook message.

### 7.1 Worksheet roles relative to the PDF output

The PDF (`SavePDF` / `EmailPDF`) renders **only four sheets**: Summary, Summary (2),
Summary Others, SummaryGraph. Tracing every cross-sheet cell reference back from those four
(by dependency analysis of the workbook) sorts all 30 sheets into three tiers:

| Tier | Sheets |
|---|---|
| **Rendered in the PDF** | Summary · Summary (2) · Summary Others · SummaryGraph |
| **Feed the PDF (referenced upstream)** | HRVOC to TOs Flare Calculations · 50-2 to TOs Flare Calculations · Natural Gas CO & NOx Emissions · 35-12 Flare Calculations · 105-01/02/03 Flare Calculations · Raw Data · Formulas · TO_A · TO_B · HRVOC_FLARE · F050_02 · F035_12 · F105_01 · F105_02 · F105_03 · TO_A_CSI · TO_B_CSI · HRVOC_FLARE_CSI · F050_02_CSI · F035_12_CSI · Minute |
| **No purpose in the PDF output** | **Settings · DateSelection · Variables** |

**No purpose in the PDF output** — `Settings`, `DateSelection`, and `Variables` are never
referenced by any sheet in the PDF dependency chain. Their role is purely **operational**:
`Settings` builds the ODBC connection, `DateSelection` chooses the report day, and `Variables`
derives the date parts, file name, and save path. They are essential to *run* the job but
contribute nothing to the rendered PDF content. In an SSRS port these become **report
parameters and subscription / data-source settings**, not report content.

Two caveats on the "feed the PDF" tier:

- **105-01 / 105-02 render but aren't populated.** Their calculation sheets *are* referenced by
  Summary Others (so they occupy pages in the PDF), but their source queries (`F105_01` /
  `F105_02`) are commented out in the daily job — only `F105_03` loads. In a daily run those
  pages show stale/empty values, so they have no *live* purpose in the daily PDF until the
  queries are re-enabled (see §8.5).
- The data funnels through the **`Raw Data`** sheet, which reads the raw landing sheets
  (`TO_A`, `TO_B`, `HRVOC_FLARE`, `F050_02`); the 35-12 and 105-x calc sheets instead read
  `F035_12!` / `F105_0x!` directly.

---

## 8. Observations & potential issues

These are noted for maintenance; none were changed as part of this documentation.

1. **Server placeholder / production migration** — `Settings!B3` is still `SQL1`. The source data
   (pushed by **UCOS**) is being migrated to a new **production SQL Server**; once the
   `Reports15min` tables are in place there, point the workbook at it by setting `Settings!B3`
   (Server) — and `Settings!B4` (Database) if the name changes. No code change is required; the
   connection is built from those cells (see §3.1).
2. **105-01 / 105-02 sheet labels** — the 105-01 and 105-02 calculation sheets carry header text that
   reads "105-03"; the formulas reference the correct `F105_01!` / `F105_02!` ranges, so it appears to be
   a copy-paste labeling artifact rather than a calc error — worth confirming.
3. **105-02 `G4`** references `F105_01!B2` (not `F105_02!B2`) — likely a copy-paste bug.
4. **105-01 `D4`** divides the meter reading by `10000`/`1000` inconsistently inside the cubic fit, and
   **105-02 `D4`** lists the cubic coefficients in a different order (D28·x³ … D30·x) than the other
   sheets (D30·x³ … D28·x). These three 105-x variants are worth reconciling against the intended curve fit.
5. **`F105_01` / `F105_02`** queries and value-paste steps are commented out in several modules; only
   `F105_03` is active in the daily path — confirm whether 105-1/105-2 should be reporting.
6. **EmailPDF** has empty `.To/.CC/.BCC` and selects "Summary Others" twice in its sheet array;
   recipients presumably come from the Variables email cells but aren't wired in.
7. **Legacy artifacts** — `Variables!A1 = "V1.20.2009"` and `APP=Microsoft Office XP` (since removed)
   indicate the workbook's age; the SQL date filter uses `CONVERT(CHAR(10),…,120)`, which is fine but
   returns a text-day match (no time component), so partial-day or time-zone nuances aren't handled.

---

## 9. Change history (v1 → this reference version)

1. **VBA project password removed** (project is now viewable/editable).
2. **All 24 SQL queries redirected** from a hard-coded File DSN (`ITC-PHA-1-SA.dsn`, database
   `CSIReportsDB`) to the DSN-less `DBConnection()` builder reading the **Settings** sheet.
3. **Settings worksheet added** — Server, Database, Authentication (dropdown), ODBC Driver (dropdown),
   Username/Password; connection is now configurable without touching code.
4. **`SleepVBA` modernized** to `Application.Wait` (no `kernel32` declare; 32/64-bit safe).
5. Compiled p-code was purged so Excel recompiled cleanly from source on first open (confirmed — Excel
   re-saved this version with regenerated compiled caches).
6. **Worksheet protection** added on the 11 formula sheets (macro-safe; see §10.1).
7. **Workbook structure locked** so sheets can't be added/deleted/renamed/hidden (macro-safe; see §10.2).
8. **VBA project password** — to be set manually with `Innovation2026` (see §10.3).

---

## 10. Protection

The reference workbook is hardened against accidental edits. All protection uses the password
`Innovation2026` and is **macro-safe** — the daily/monthly jobs still run.

### 10.1 Worksheet protection (formula sheets)
Eleven formula sheets are protected read-only so users cannot change the calculations: the seven
flare/calc sheets (HRVOC to TOs, 50-2 to TOs, Natural Gas CO & NOx, 35-12, 105-01/02/03), the
three Summary sheets, and the Formulas constants sheet.

- Applied at open by `LockFormulaSheets` (in `ThisWorkbook.Workbook_Open`) with
  `Protect Password:="Innovation2026", UserInterfaceOnly:=True`. `UserInterfaceOnly` lets the
  macros keep writing while blocking the user; recalculation is unaffected.
- The macros never write to these sheets (they write only to the landing sheets), so protection
  does not interfere with the imports or the report export.
- **Left editable:** Settings, DateSelection, Variables (inputs/config); Raw Data (`SaveXL` pastes
  values onto its copy); and the raw landing sheets (macro-written).

### 10.2 Workbook structure protection
The workbook structure is locked (`Protect Structure:=True`) so sheets cannot be added, deleted,
renamed, moved, or hidden/unhidden by the user.

- There is **no** `UserInterfaceOnly` equivalent for workbook protection, so the routines that
  change sheet structure bracket their operations with `BookUnlock` / `BookLock` (both in the
  `Functions` module): `HideCalcs` (hides sheets) and the sheet-`.Copy` export in `SaveXL`,
  `DailyJob`, and `MonthlyJob`. Structure is (re)locked on each open by `BookLock` in
  `Workbook_Open`.

### 10.3 VBA project password (manual step)
The VBA project should be locked for viewing with the same password. This is **not** set in the
delivered file — it is a one-time manual step (automating it means writing an unverifiable
encrypted record into the macro binary, which risks corrupting the project):

> Alt + F11 → Tools → VBAProject Properties → Protection → check **"Lock project for viewing"** →
> enter `Innovation2026` twice → OK → Save.

### 10.4 Caveat
Excel worksheet/workbook protection and the VBA project password are **deterrents, not
encryption** — they prevent casual or accidental edits but are removable by a determined user.
For a hard guarantee that the formulas cannot be changed or seen, move the calculations into
SQL/SSRS, where the logic lives server-side and the workbook is no longer the source of truth.

---
## Appendix A — Cell formula reference (per calculation sheet)
Exact formulas as they appear in the workbook. Conventions:
- **Per-minute** = the formula in the first data row (row 4); it is filled down one row per minute (≈ rows 4–1443). Row-4 references to `'Raw Data'!…6`, `F035_12!…2`, `F105_0x!…2` advance with each row.
- **Daily total** = the row-1 cell (either `SUM(col)/60` to integrate lb/hr-minute → lb, or a pointer such as `=N1444`).
- Factor references (`Formulas!$F$/$G$/$H$…`) are the temperature-band tables in §4.4; curve-fit and conversion constants are in §4.1/§4.3.

**`Raw Data` column map** (what the formulas read):
| Col | Tag / meaning | | Col | Tag / meaning |
|---|---|---|---|---|
| A | Date/Time | | I | Vread SCFM 50-2 |
| B | MW read HRVOC | | J | TE-B — TO-B temp °F |
| C | Vread SCFM HRVOC | | K | Valve → TO-A (HRVOC) |
| D | TE-A — TO-A temp °F | | L | Valve → TO-B (HRVOC) |
| E | Fng SCFM (natural gas) | | M | Valve → HRVOC flare |
| F | FCVng TO-A % open | | N | Valve → TO-A (50-2) |
| G | FCVng TO-B % open | | O | Valve → TO-B (50-2) |
| H | MW read 50-2 | | P | Valve → 50-2 flare |

### HRVOC to TOs Flare Calculations
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** MW calc HRVOC Bnr — per-minute: `=(Formulas!$D$30*('Raw Data'!B6)^3)+(Formulas!$D$29*('Raw Data'!B6)^2)+(Formulas!$D$28*('Raw Data'!B6))+Formulas!$D$27`
- **[E]** MW act HRVOC Bnr — per-minute: `=IF(D4<Formulas!$B$76,28,D4)`
- **[F]** fraction of BD in HRVOC Flare Gas Stream — per-minute: `=(E4-28)/26`
- **[G]** lbs/hr of BD in HRVOC Flare Gas Stream — per-minute: `=Formulas!$B$15*F4*'Raw Data'!C6`
- **[H]** fraction to  TO-A  HRVOC Bnr — per-minute: `=IF(ISERR('Raw Data'!K6/('Raw Data'!K6+'Raw Data'!L6+'Raw Data'!M6)),0,'Raw Data'!K6/('Raw Data'!K6+'Raw Data'!L6+'Raw Data'!M6))`
- **[I]** fraction to  TO-B  HRVOC Bnr — per-minute: `=IF(ISERROR('Raw Data'!L6/('Raw Data'!K6+'Raw Data'!L6+'Raw Data'!M6)),0,'Raw Data'!L6/('Raw Data'!K6+'Raw Data'!L6+'Raw Data'!M6))`
- **[J]** fraction to HRVOC Flare — per-minute: `=IF(ISERROR('Raw Data'!M6/('Raw Data'!K6+'Raw Data'!L6+'Raw Data'!M6)),0,'Raw Data'!M6/('Raw Data'!K6+'Raw Data'!L6+'Raw Data'!M6))`
- **[K]** lbs/hr of BD to TO-A  HRVOC Bnr — per-minute: `=IF($E4<=Formulas!$B$76,0,H4*G4)` — daily total: `=SUM(K5:K1443)/60`
- **[L]** fraction emissions — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$H$48, IF('Raw Data'!D6>Formulas!$D$47,Formulas!$H$47, IF('Raw Data'!D6>Formulas!$D$46,Formulas!$H$46, IF('Raw Data'!D6>Formulas!$D$45,Formulas!$H$45, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$H$44, Formulas!$H$43)))))`
- **[M]** lbs/hr emission — per-minute: `=K4*L4`
- **[N]** lbs emission — daily total: `=N1444`
- **[O]** lbs/hr of BD to TO-B  HRVOC Bnr — per-minute: `=IF($E4<=Formulas!$B$76,0,I4*G4)` — daily total: `=SUM(O5:O1443)/60`
- **[P]** fraction emissions — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$H$56, IF('Raw Data'!J6>Formulas!$D$55,Formulas!$H$55, IF('Raw Data'!J6>Formulas!$D$54,Formulas!$H$54, IF('Raw Data'!J6>Formulas!$D$53,Formulas!$H$53, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$H$52, Formulas!$H$51)))))`
- **[Q]** lbs/hr emission — per-minute: `=O4*P4`
- **[R]** lbs emission — daily total: `=SUM(R5:R1443)`
- **[S]** lbs/hr of BD to HRVOC Flare — per-minute: `=IF($E4<=Formulas!$B$76,0,J4*G4)` — daily total: `=SUMIF(S4:S1443,"<>#N/A")/60`
- **[T]** fraction emissions — per-minute: `=IF('Raw Data'!C6 < 1035,Formulas!$H$49,0.07)`
- **[U]** HRVOC lbs/hr emission — per-minute: `=S4*T4`
- **[V]** HRVOC lbs emission — daily total: `=SUM(V5:V1443)`
- **[W]** SCFM of  HRVOC  to TO-A — per-minute: `='Raw Data'!C6*F4*H4`
- **[X]** MMBTU/hr — per-minute: `=(((W4*Formulas!$B$20))*60)/1000000`
- **[Y]** CO factor lbs CO /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$G$48, IF('Raw Data'!D6>Formulas!$D$47,Formulas!$G$47, IF('Raw Data'!D6>Formulas!$D$46,Formulas!$G$46, IF('Raw Data'!D6>Formulas!$D$45,Formulas!$G$45, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$G$44,  Formulas!$G$43)))))`
- **[Z]** CO lbs/hr emission — per-minute: `=Y4*X4`
- **[AA]** CO lbs emission — daily total: `=AA1444`
- **[AB]** SCFM of  HRVOC  to TO-B — per-minute: `='Raw Data'!C6*F4*I4`
- **[AC]** MMBTU/hr — per-minute: `=(((AB4*Formulas!$B$20))*60)/1000000`
- **[AD]** CO factor lbs CO /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$56,Formulas!$G$56, IF('Raw Data'!D6>Formulas!$D$55,Formulas!$G$55, IF('Raw Data'!D6>Formulas!$D$54,Formulas!$G$54, IF('Raw Data'!D6>Formulas!$D$53,Formulas!$G$53, IF('Raw Data'!D6>Formulas!$D$52,Formulas!$G$52,  Formulas!$G$51)))))`
- **[AE]** CO lbs/hr emission — per-minute: `=AD4*AC4`
- **[AF]** CO lbs emission — daily total: `=AF1444`
- **[AG]** SCFM of  BD to  HRVOC FLare — per-minute: `='Raw Data'!C6*F4*J4`
- **[AH]** MMBTU/hr — per-minute: `=((AG4*Formulas!$B$20)*60)/1000000`
- **[AJ]** CO lbs/hr emission — per-minute: `=AI4*AH4`
- **[AK]** CO lbs emission — daily total: `=AK1444`
- **[AL]** SCFM of  HRVOC to  TO-A — per-minute: `=W4`
- **[AM]** MMBTU/hr — per-minute: `=(((AL4*Formulas!$B$20))*60)/1000000`
- **[AN]** NOx factor lbs NOx /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$F$48, IF('Raw Data'!D6>Formulas!$D$47,Formulas!$F$47, IF('Raw Data'!D6>Formulas!$D$46,Formulas!$F$46, IF('Raw Data'!D6>Formulas!$D$45,Formulas!$F$45, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$F$44,  Formulas!$F$43)))))`
- **[AO]** NOx lbs/hr emission — per-minute: `=AN4*AM4`
- **[AP]** NOx lbs emission — daily total: `=AP1444`
- **[AQ]** SCFM of  HRVOC to  TO-B — per-minute: `=AB4`
- **[AR]** MMBTU/hr — per-minute: `=(((AQ4*Formulas!$B$20))*60)/1000000`
- **[AS]** NOx factor lbs NOx /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$56,Formulas!$F$56, IF('Raw Data'!D6>Formulas!$D$55,Formulas!$F$55, IF('Raw Data'!D6>Formulas!$D$54,Formulas!$F$54, IF('Raw Data'!D6>Formulas!$D$53,Formulas!$F$53, IF('Raw Data'!D6>Formulas!$D$52,Formulas!$F$52,  Formulas!$F$51)))))`
- **[AT]** NOx lbs/hr emission — per-minute: `=AS4*AC4`
- **[AU]** NOx lbs emission — daily total: `=AU1444`
- **[AV]** SCFM of  BD to HRVOC Flare — per-minute: `=AG4`
- **[AW]** MMBTU/hr — per-minute: `=((AV4*Formulas!$B$20)*60)/1000000`
- **[AY]** NOx lbs/hr emission — per-minute: `=AX4*AW4`
- **[AZ]** NOx lbs emission — daily total: `=AZ1444`
- **[BA]** Total lbs of BD Sent to TOs — daily total: `=BA1444`
- **[BB]** Total lbs of BD Sent to Tos @ 93% Efficiency — per-minute: `=IF(L4<Formulas!$H$43,0,K4/60)`
- **[BC]** HRVOC or 50-2  MW above NO2 — per-minute: `=IF($E4>Formulas!$B$76,"Yes","No")`

### 50-2 to TOs Flare Calculations
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** MW calc 50-2 Bnr — per-minute: `=(Formulas!$D$30*('Raw Data'!H6)^3)+(Formulas!$D$29*('Raw Data'!H6)^2)+(Formulas!$D$28*('Raw Data'!H6))+Formulas!$D$27`
- **[E]** MW act 50-2  Bnr — per-minute: `=IF(D4<Formulas!$B$76,28,D4)`
- **[F]** fraction of BD in 50-2 Flare Gas Stream — per-minute: `=(E4-28)/26`
- **[G]** lbs/hr of BD in 50-2 Flare Gas Stream — per-minute: `=Formulas!$B$15*F4*'Raw Data'!I6`
- **[H]** fraction to  TO-A  50-2 Bnr — per-minute: `=IF('Raw Data'!N6+'Raw Data'!O6+'Raw Data'!P6=0,0,'Raw Data'!N6/('Raw Data'!N6+'Raw Data'!O6+'Raw Data'!P6))`
- **[I]** fraction to  TO-B  50-2 Bnr — per-minute: `=IF('Raw Data'!N6+'Raw Data'!O6+'Raw Data'!P6=0,0,'Raw Data'!O6/('Raw Data'!N6+'Raw Data'!O6+'Raw Data'!P6))`
- **[J]** fraction to 50-2 Flare — per-minute: `=IF('Raw Data'!N6+'Raw Data'!O6+'Raw Data'!P6=0,0,'Raw Data'!P6/('Raw Data'!N6+'Raw Data'!O6+'Raw Data'!P6))`
- **[K]** lbs/hr of BD to TO-A  50-2 Bnr — per-minute: `=IF($E4<=Formulas!$B$76,0,H4*G4)` — daily total: `=SUMIF(K4:K1443,"<>#N/A")/60`
- **[L]** fraction emissions — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$H$56, IF('Raw Data'!J6>Formulas!$D$55,Formulas!$H$55, IF('Raw Data'!J6>Formulas!$D$54,Formulas!$H$54, IF('Raw Data'!J6>Formulas!$D$53,Formulas!$H$53, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$H$52, Formulas!$H$51)))))`
- **[M]** lbs/hr emission — per-minute: `=IF(K4=0,0,IF(L4=0,0,K4*L4))`
- **[N]** lbs emission — daily total: `=SUM(N5:N1443)`
- **[O]** lbs/hr of BD to TO-B  50-2 Bnr — per-minute: `=IF($E4<=Formulas!$B$76,0,I4*G4)` — daily total: `=SUM(O4:O1443)/60`
- **[P]** fraction emissions — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$H$56,IF('Raw Data'!J6>Formulas!$D$55,Formulas!$H$55, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$H$52,Formulas!$H$51)))`
- **[Q]** lbs/hr emission — per-minute: `=O4*P4`
- **[R]** lbs emission — daily total: `=SUM(R5:R1443)`
- **[S]** lbs/hr of BD to 50-2 Flare — per-minute: `=IF($E4<=Formulas!$B$76,0,J4*G4)` — daily total: `=SUM(S4:S1443)/60`
- **[T]** fraction emissions — per-minute: `=IF('Raw Data'!I6<639, 0.02, 0.07)`
- **[U]** HRVOC lbs/hr emission — per-minute: `=S4*T4`
- **[V]** HRVOC lbs emission — daily total: `=SUM(V5:V1443)`
- **[W]** SCFM of  50-2 to TO-A — per-minute: `='Raw Data'!I6*F4*H4`
- **[X]** MMBTU/hr — per-minute: `=(((W4*Formulas!$B$20))*60)/1000000`
- **[Y]** CO factor lbs CO /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$G$48,IF('Raw Data'!D6>Formulas!$D$47,Formulas!$G$47, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$G$44,Formulas!$G$43)))`
- **[Z]** CO lbs/hr emission — per-minute: `=Y4*X4`
- **[AA]** CO lbs emission — daily total: `=AA1444`
- **[AB]** SCFM of  50-2 to TO-B — per-minute: `='Raw Data'!I6*F4*I4`
- **[AC]** MMBTU/hr — per-minute: `=(((AB4*Formulas!$B$20))*60)/1000000`
- **[AD]** CO factor lbs CO /MMBtu — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$G$56,IF('Raw Data'!J6>Formulas!$D$55,Formulas!$G$55, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$G$52,Formulas!$G$51)))`
- **[AE]** CO lbs/hr emission — per-minute: `=AD4*AC4`
- **[AF]** CO lbs emission — daily total: `=AF1444`
- **[AG]** SCFM of  BD to  HRVOC FLare — per-minute: `='Raw Data'!I6*F4*J4`
- **[AH]** MMBTU/hr — per-minute: `=((AG4*Formulas!$B$20)*60)/1000000`
- **[AJ]** CO lbs/hr emission — per-minute: `=AH4*AI4`
- **[AK]** CO lbs emission — daily total: `=AK1444`
- **[AL]** SCFM of  50-2 to  TO-A — per-minute: `=W4`
- **[AM]** MMBTU/hr — per-minute: `=((((AL4*Formulas!$B$20))*60)/1000000)`
- **[AN]** NOx factor lbs NOx /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$F$48,IF('Raw Data'!D6>Formulas!$D$47,Formulas!$F$47, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$F$44,Formulas!$F$43)))`
- **[AO]** NOx lbs/hr emission — per-minute: `=AN4*AM4`
- **[AP]** NOx lbs emission — daily total: `=AP1444`
- **[AQ]** SCFM of  50-2 to  TO-B — per-minute: `=AB4`
- **[AR]** MMBTU/hr — per-minute: `=((((AQ4*Formulas!$B$20))*60)/1000000)`
- **[AS]** NOx factor lbs NOx /MMBtu — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$F$56,IF('Raw Data'!J6>Formulas!$D$55,Formulas!$F$55, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$F$52,Formulas!$F$51)))`
- **[AT]** NOx lbs/hr emission — per-minute: `=AS4*AR4`
- **[AU]** NOx lbs emission — daily total: `=AU1444`
- **[AV]** SCFM of  50-2 to HRVOC Flare — per-minute: `=AG4`
- **[AW]** MMBTU/hr — per-minute: `=((AV4*Formulas!$B$20)*60)/1000000`
- **[AY]** NOx lbs/hr emission — per-minute: `=AX4*AW4`
- **[AZ]** NOx lbs emission — daily total: `=AZ1444`

### Natural Gas CO & NOx Emissions
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** Fng (SCFM) — per-minute: `='Raw Data'!E6`
- **[E]** FCVng  TO-A  (% open) — per-minute: `='Raw Data'!F6`
- **[F]** FCVng  TO-B  (% open) — per-minute: `='Raw Data'!G6`
- **[G]** SCFM to TO-A — per-minute: `=IF(E4+F4<=0,0,IF((20+((D4-40)*(E4/(E4+F4))))<0,0,20+((D4-40)*(E4/(E4+F4)))))`
- **[H]** SCFM to TO-B — per-minute: `=IF(E4+F4<=0,0,IF((20+((D4-40)*(F4/(E4+F4))))<0,0,20+((D4-40)*(F4/(E4+F4)))))`
- **[I]** MMBtu/hr to TO-A — per-minute: `=((G4*Formulas!$B$23)*60)/1000000`
- **[J]** MMBtu/hr to TO-B — per-minute: `=((H4*Formulas!$B$23)*60)/1000000`
- **[K]** CO factor lbs CO /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$G$48, IF('Raw Data'!D6>Formulas!$D$47,Formulas!$G$47, IF('Raw Data'!D6>Formulas!$D$46,Formulas!$G$46, IF('Raw Data'!D6>Formulas!$D$45,Formulas!$G$45, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$G$44,Formulas!$G$43)))))`
- **[L]** CO lbs/hr emission — per-minute: `=K4*I4`
- **[M]** CO lbs emission — daily total: `=M1444`
- **[N]** CO factor lbs CO /MMBtu — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$G$56, IF('Raw Data'!J6>Formulas!$D$55,Formulas!$G$55, IF('Raw Data'!J6>Formulas!$D$54,Formulas!$G$54, IF('Raw Data'!J6>Formulas!$D$53,Formulas!$G$53, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$G$52,Formulas!$G$51)))))`
- **[O]** CO lbs/hr emission — per-minute: `=N4*J4`
- **[P]** CO lbs emission — daily total: `=P1444`
- **[Q]** NOx factor lbs NOx /MMBtu — per-minute: `=IF('Raw Data'!D6>Formulas!$D$48,Formulas!$F$48, IF('Raw Data'!D6>Formulas!$D$47,Formulas!$F$47, IF('Raw Data'!D6>Formulas!$D$46,Formulas!$F$46, IF('Raw Data'!D6>Formulas!$D$45,Formulas!$F$45, IF('Raw Data'!D6>Formulas!$D$44,Formulas!$F$44,Formulas!$F$43)))))`
- **[R]** NOx lbs/hr emission — per-minute: `=Q4*I4`
- **[S]** NOx lbs emission — daily total: `=S1444`
- **[T]** NOx factor lbs NOx /MMBtu — per-minute: `=IF('Raw Data'!J6>Formulas!$D$56,Formulas!$F$56, IF('Raw Data'!J6>Formulas!$D$55,Formulas!$F$55, IF('Raw Data'!J6>Formulas!$D$54,Formulas!$F$54, IF('Raw Data'!J6>Formulas!$D$53,Formulas!$F$53, IF('Raw Data'!J6>Formulas!$D$52,Formulas!$F$52,Formulas!$F$51)))))`
- **[U]** NOx lbs/hr emission — per-minute: `=T4*J4`
- **[V]** NOx lbs emission — daily total: `=V1444`

### 35-12 Flare Calculations
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** MW calc 35-12 Bnr — per-minute: `=(Formulas!$D$35*(F035_12!A2)^3)+(Formulas!$D$34*(F035_12!A2)^2)+(Formulas!$D$33*(F035_12!A2))+Formulas!$D$32`
- **[E]** MW act 35-12  Bnr — per-minute: `=IF(D4<Formulas!B76,28,D4)`
- **[F]** fraction of BU in 35-12 Flare Gas Stream — per-minute: `=(E4-28)/26`
- **[G]** lbs/hr of BU in 35-12 Flare Gas Stream — per-minute: `=Formulas!$B$16*F4*F035_12!B2`
- **[H]** lbs/hr of BU to 35-12 Flare — per-minute: `=IF($E4<=Formulas!$B$76,0,IF(G4<0,0,G4))` — daily total: `=SUMIF(H4:H1443,"<>#N/A")/60`
- **[I]** fraction emissions — per-minute: `=Formulas!$B$72`
- **[J]** 35-12 lbs/hr emission — per-minute: `=H4*I4`
- **[K]** 35-12 lbs emission — daily total: `=K1444`
- **[L]** SCFM of  BU to  35-12 FLare — per-minute: `=IF(F035_12!B2<0,0,F035_12!B2)`
- **[M]** MMBTU/hr — per-minute: `=((L4*Formulas!$B$21)*60)/1000000`
- **[N]** CO factor lbs CO /MMBtu — per-minute: `=Formulas!$B$74`
- **[O]** CO lbs/hr Emission — per-minute: `=M4*N4`
- **[P]** CO lbs Emission — daily total: `=P1444`
- **[Q]** SCFM of  BU to 35-12 Flare — per-minute: `=L4`
- **[R]** MMBTU/hr — per-minute: `=((Q4*Formulas!$B$21)*60)/1000000`
- **[S]** NOx factor lbs NOx /MMBtu — per-minute: `=Formulas!$B$75`
- **[T]** NOx lbs/hr Emission — per-minute: `=S4*R4`
- **[U]** NOx lbs Emission — daily total: `=U1444`

### 105-01 Flare Calculations
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** MW calc 105-03 Bnr — per-minute: `=(Formulas!$D$30*(F105_01!A2/10000)^3)+(Formulas!$D$29*(F105_01!A2/10000)^2)+(Formulas!$D$28*(F105_01!A2/1000))+Formulas!$D$27`
- **[E]** MW act 105-03  Bnr — per-minute: `=IF(D4<Formulas!$B$76,28,D4)`
- **[F]** fraction of BD in 105-03 Flare Gas Stream — per-minute: `=(E4-28)/26`
- **[G]** lbs/hr of BD in 105-03 Flare Gas Stream — per-minute: `=Formulas!$B$15*F4*F105_01!B2`
- **[H]** lbs/hr of BD to 105-03 Flare — per-minute: `=IF(E4<=Formulas!B76,0,IF(G4<0,0,G4))` — daily total: `=SUMIF(H4:H1443,"<>#N/A")/60`
- **[I]** fraction emissions — per-minute: `=Formulas!$B$73`
- **[J]** 105-03 lbs/hr emission — per-minute: `=H4*I4`
- **[K]** 105-03 lbs emission — daily total: `=K1444`
- **[L]** SCFM of  BD to  105-03 FLare — per-minute: `=IF(F105_01!B2<0,0,F105_01!B2)`
- **[M]** MMBTU/hr — per-minute: `=((L4*Formulas!$B$20)*60)/1000000`
- **[N]** CO factor lbs CO /MMBtu — per-minute: `=Formulas!$B$74`
- **[O]** CO lbs/hr emission — per-minute: `=M4*N4`
- **[P]** CO lbs emission — daily total: `=P1444`
- **[Q]** SCFM of  BD to 105-03 Flare — per-minute: `=L4`
- **[R]** MMBTU/hr — per-minute: `=((Q4*Formulas!$B$20)*60)/1000000`
- **[S]** NOx factor lbs NOx /MMBtu — per-minute: `=Formulas!$B$75`
- **[T]** NOx lbs/hr emission — per-minute: `=S4*R4`
- **[U]** NOx lbs emission — daily total: `=U1444`

### 105-02 Flare Calculations
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** MW calc 105-03 Bnr — per-minute: `=(Formulas!$D$28*(F105_02!A2)^3)+(Formulas!$D$29*(F105_02!A2)^2)+(Formulas!$D$30*(F105_02!A2))+Formulas!$D$27`
- **[E]** MW act 105-03  Bnr — per-minute: `=IF(D4<Formulas!$B$76,28,D4)`
- **[F]** fraction of BD in 105-03 Flare Gas Stream — per-minute: `=(E4-28)/26`
- **[G]** lbs/hr of BD in 105-03 Flare Gas Stream — per-minute: `=Formulas!$B$15*F4*F105_01!B2`
- **[H]** lbs/hr of BD to 105-03 Flare — per-minute: `=IF(E4<=Formulas!$B$76,0,IF(G4<0,0,G4))` — daily total: `=SUM(H4:H1443)/60`
- **[I]** fraction emissions — per-minute: `=Formulas!$B$73`
- **[J]** 105-03 lbs/hr emission — per-minute: `=H4*I4`
- **[K]** 105-03 lbs emission — daily total: `=K1444`
- **[L]** SCFM of  BD to  105-03 FLare — per-minute: `=IF(F105_02!B2<0,0,F105_02!B2)`
- **[M]** MMBTU/hr — per-minute: `=((L4*Formulas!$B$20)*60)/1000000`
- **[N]** CO factor lbs CO /MMBtu — per-minute: `=Formulas!$B$74`
- **[O]** CO lbs/hr emission — per-minute: `=M4*N4`
- **[P]** CO lbs emission — daily total: `=P1444`
- **[Q]** SCFM of  BD to 105-03 Flare — per-minute: `=L4`
- **[R]** MMBTU/hr — per-minute: `=((Q4*Formulas!$B$20)*60)/1000000`
- **[S]** NOx factor lbs NOx /MMBtu — per-minute: `=Formulas!$B$75`
- **[T]** NOx lbs/hr emission — per-minute: `=S4*R4`
- **[U]** NOx lbs emission — daily total: `=U1444`

### 105-03 Flare Calculations
- **[A]** Date — per-minute: `=Summary!$B$1`
- **[B]** Time — per-minute: `='Raw Data'!A6`
- **[D]** MW calc 105-03 Bnr — per-minute: `=(Formulas!$D$30*(F105_03!A2)^3)+(Formulas!$D$29*(F105_03!A2)^2)+(Formulas!$D$28*(F105_03!A2))+Formulas!$D$27`
- **[E]** MW act 105-03  Bnr — per-minute: `=IF(D4<Formulas!$B$76,28,D4)`
- **[F]** fraction of BD in 105-03 Flare Gas Stream — per-minute: `=(E4-28)/26`
- **[G]** lbs/hr of BD in 105-03 Flare Gas Stream — per-minute: `=Formulas!$B$15*F4*F105_03!B2`
- **[H]** lbs/hr of BD to 105-03 Flare — per-minute: `=IF(G4<0,0,G4)` — daily total: `=SUM(H4:H1443)/60`
- **[I]** fraction emissions — per-minute: `=Formulas!$B$73`
- **[J]** 105-03 lbs/hr emission — per-minute: `=H4*I4`
- **[K]** 105-03 lbs emission — daily total: `=K1444`
- **[L]** SCFM of  BD to  105-03 FLare — per-minute: `=IF(F105_03!B2<0,0,F105_03!B2)`
- **[M]** MMBTU/hr — per-minute: `=((L4*Formulas!$B$20)*60)/1000000`
- **[N]** CO factor lbs CO /MMBtu — per-minute: `=Formulas!$B$74`
- **[O]** CO lbs/hr emission — per-minute: `=M4*N4`
- **[P]** CO lbs emission — daily total: `=P1444`
- **[Q]** SCFM of  BD to 105-03 Flare — per-minute: `=L4`
- **[R]** MMBTU/hr — per-minute: `=((Q4*Formulas!$B$20)*60)/1000000`
- **[S]** NOx factor lbs NOx /MMBtu — per-minute: `=Formulas!$B$75`
- **[T]** NOx lbs/hr emission — per-minute: `=S4*R4`
- **[U]** NOx lbs emission — daily total: `=U1444`
