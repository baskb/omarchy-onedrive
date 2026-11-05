# Testing

## Parsers

```
node Model.test.js
```

covers every journal and command parser in `Model.js`, the run estimate, and
the settings helpers. It needs only Node.

## Manifest

```
omarchy plugin validate .
```

## A fake sync run, without touching your OneDrive

`fake-journal.sh` prints journal-shaped JSON lines: a sync start, "200 items
to download", then one finished file per second. To see the whole-run bar,
the bar percentage and the progress line without real traffic:

1. In `Service.qml`, inside `startJournal()`, temporarily replace the
   `journalctl` argument list with `["/absolute/path/to/test/fake-journal.sh"]`.
2. `omarchy restart shell` (Service.qml is not hot-reloaded).
3. Open the panel after ~15 seconds. `omarchy-shell baskb.onedrive status`
   prints the same figures.
4. Restore `Service.qml` and restart the shell again.

Timestamps in the fake lines are the current time, so they count as live
events rather than history.
