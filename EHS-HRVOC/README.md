# ITC Emissions Reporting

Artifacts for ITC's HRVOC emissions-reporting workbook (CO & NOx daily/monthly
reports) and its modernization — connection, configuration, VBA, documentation,
and the SQL/SSRS migration groundwork.

## Contents

| Path | What it is |
|------|------------|
| `workbooks/EmissionsCalculations_claude_v2_protected.xlsm` | Current workbook — DSN-less ODBC connection via the **Settings** sheet, 64-bit-safe VBA, and worksheet protection on the formula/calc sheets (password-protected; see docs). |
| `workbooks/EmissionsCalculations_claude_v2_REFERENCE.xlsm` | Reference snapshot of v2 (pre-protection) used as the baseline for the documentation. |
| `docs/EmissionsCalculations_Technical_Documentation.md` | Full technical documentation — architecture, data flow, SQL source, calculation methodology, VBA module reference, the worksheet-role/PDF analysis, and a per-sheet cell-formula appendix. |
| `sql/Formulas_ReferenceTables.sql` | The Excel **Formulas** sheet rebuilt as SQL Server reference tables (compound constants, MW curve-fit coefficients, TO-A/TO-B temperature-band emission factors, flare-tip data) plus a verified banded-factor lookup function — for the SSRS/SQL port. |
| `slides/EmissionsCalculations_Functional_Changes.pptx` | Summary deck of the v1 → v2 functional changes. |

## Notes

- The database connection is configured in the workbook's **Settings** sheet
  (Server, Database, Authentication, ODBC Driver). The `Server` value is a
  placeholder (`SQL1`) — set the real instance before a production run.
- Worksheet protection and the VBA project password use the password documented
  with the delivery. Both are deterrents, not encryption.
- No emission calculations were changed in the modernization; see the technical
  documentation for the full before/after.
