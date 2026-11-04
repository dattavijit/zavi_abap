# zavi_abap

Avi's personal ABAP utilities (target system A4H, package `$AVI`).

## ZAVI_SCMON_BY_USER

Approximates **SCMON usage per user**. SCMON doesn't record users, so the report:

1. Reads STAD statistics records via `SWNC_STATREC_READ` for the chosen user and time window, and collects the distinct entry points (transactions, reports, RFC/HTTP IDs) with that user's step counts.
2. Matches those entry points against `SCMON_VDATA.rootname` and sums `counter` per entry point / object / procedure, then shows the result in a SALV list.

Source: [`src/zavi_scmon_by_user.prog.abap`](src/zavi_scmon_by_user.prog.abap)

### Caveats

- **Counts are system-wide.** SCMON has no user field; a row only means this user started an entry point that SCMON saw reaching that code.
- **Rootname-only match.** Root type is not compared, so a transaction and a report with the same name can be conflated.
- **STAD retention is ~48 h by default** (`stat/max_files`); SCMON slices are day-granular.
- **Not yet syntax-checked or activated on A4H.** The `@p_slice = @abap_false` condition may need splitting under strict SQL mode.
