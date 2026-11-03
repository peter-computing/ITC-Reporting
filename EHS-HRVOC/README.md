# ITC Emissions Reporting

Artifacts for ITC's HRVOC emissions-reporting workbook (CO & NOx daily/monthly
reports) and its modernization — connection, configuration, VBA, documentation,
and the SQL/SSRS migration groundwork.

## Contents

| Path | What it is |
|------|------------|
| `workbooks/EmissionsCalculations.xlsm` | Current workbook (v2) — DSN-less ODBC connection via the **Settings** sheet and 64-bit-safe VBA (`Application.Wait` in place of the old Sleep API). Opens cleanly with no macro-corruption prompt. Protection is applied separately via native VBA import (`modProtection.bas`), not baked into this file. |
| `docs/EmissionsCalculations_Technical_Documentation.md` | Full technical documentation — architecture, data flow, SQL source, calculation methodology, VBA module reference, the worksheet-role/PDF analysis, and a per-sheet cell-formula appendix. |
| `sql/Formulas_ReferenceTables.sql` | The Excel **Formulas** sheet rebuilt as SQL Server reference tables (compound constants, MW curve-fit coefficients, TO-A/TO-B temperature-band emission factors, flare-tip data) plus a verified banded-factor lookup function — for the SSRS/SQL port. |
| `slides/EmissionsCalculations_Functional_Changes.pptx` | Summary deck of the v1 → v2 functional changes. |

## Notes

- The database connection is configured in the workbook's **Settings** sheet
  (Server, Database, Authentication, ODBC Driver). The `Server` value is a
  placeholder (`SQL1`) — set the real instance before a production run.
- The current workbook ships without protection. To lock the formula/calc
  sheets and the VBA project, import `modProtection.bas` natively in Excel and
  set the VBA project password manually (see the technical documentation).
  Protection must not be applied by editing the macro binary — doing so
  corrupts the VBA project on open.
- No emission calculations were changed in the modernization; see the technical
  documentation for the full before/after.
