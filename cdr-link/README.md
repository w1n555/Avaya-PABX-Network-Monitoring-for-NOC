# Avaya CM CDR Logger

CM **pushes** CDR to this PC (node **NMC-CDR** → `172.29.92.154`).

| Item | Value |
|------|--------|
| Listen | `0.0.0.0:9000` |
| Code | `C:\inetpub\wwwroot\CM\cdr-link\` |
| Daily logs | `C:\inetpub\wwwroot\CM\cdr-link\cdr\YYYYMMDD.txt` (lowercase) |
| Format | One **call = one line** (pipe-separated) |
| CM layout | **customized** (fixed 173 bytes / record, from Main CM) |

## Start

```bat
C:\inetpub\wwwroot\CM\cdr-link\start-cdr-logger.bat
```

Background:

```bat
C:\inetpub\wwwroot\CM\cdr-link\start-cdr-logger-background.bat
```

## CM side (you already set)

- Node name **NMC-CDR** = `172.29.92.154`
- `ip-services` CDR1 (or CDR2) → Remote Node `NMC-CDR`, Remote Port **9000**
- Firewall: allow **172.29.88.12 → 172.29.92.154:9000/TCP**
- Check: `status cdr-link` should be OK while logger is listening

## File format

Filename: `20260808.txt` (local date when record is received).

Each data line:

```text
recv_local|raw|date|time|sec_dur|cond|...|node
```

First line of a new day is a `#` header comment.

## Notes

- Logger must be **running before / while** CM link is up; CM connects out to you.
- Does not use OSSI / SAT.
- CDR Tab UI still uses mock data until we wire Search to these files.
