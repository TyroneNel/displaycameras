# SYNC.md — How code flows from local to camPi

## Ownership contract

| Area | Source of truth | Notes |
|------|-----------------|-------|
| Code (`displaycameras`, `lib/*.sh`, `omxplayer_dbuscontrol`, `*.service`, `install.sh`, `*.example`) | **Local repo → origin** | Edit locally, commit, push, then sync Pi |
| Live configs (`/etc/displaycameras/displaycameras.conf`, `layout.conf.default`, `layout.conf.1920x1080`) | **Pi `/etc` only** | Real camera URLs + passwords. Never in git (gitignored). `install.sh` never overwrites them |
| Example configs (`*.example`) | Repo | Sanitized templates with `192.168.x.x` placeholders |

## The Pi repo is frozen

`~/displaycameras.TN` on camPi is a **frozen mirror**. Its `origin` remote has
been removed, so it can neither pull nor push. It exists so the Pi has the
code history locally, but it must never diverge and never be used as a
sync channel:

- Do NOT commit in `~/displaycameras.TN`
- Do NOT `git pull` / `git push` in `~/displaycameras.TN` (no remote exists)
- Do NOT edit `/usr/lib/displaycameras/*` or `/usr/bin/displaycameras` by hand
- Files reach the Pi ONLY via `scp` from local (procedure below)

If the frozen state is ever in doubt: local `master` wins, re-run the sync.

## Sync procedure: local → Pi

Run from the local repo (`C:\dev\displaycameras`):

1. Commit + push locally, verify `git status -sb` shows `master...origin/master` (in sync).
2. `scp` the 11 code files to the Pi (NOT configs):
   - `displaycameras` → `/usr/bin/displaycameras` (0755)
   - `omxplayer_dbuscontrol` → `/usr/bin/omxplayer_dbuscontrol` (0755)
   - `lib/*.sh` (8 files) → `/usr/lib/displaycameras/` (0644)
   - `displaycameras.service` → `/etc/systemd/system/displaycameras.service` (0644)
   - Apply the same normalization `install.sh:cleanup_file` does:
     strip BOM (`sed -i '1s/^\xEF\xBB\xBF//'`), `dos2unix`, `chown root:root`.
3. `bash -n` every installed file on the Pi.
4. Verify live configs untouched: `grep -o ":554/s[0-9]" /etc/displaycameras/layout.conf.*`
5. `sudo systemctl daemon-reload`
6. Restart **sequentially, never overlapping**:
   - NEVER background `stop` and `start` at the same time — a lingering
     `stop` will run `cleanup_pid_files` mid-boot and kill the new supervisor
     (this happened 2026-10-14: monitor died instantly, all streams orphaned).
   - Preferred: `sudo systemctl restart displaycameras`, wait, then verify.
   - Manual fallback: full stop → confirm no `displaycameras`/`omxplayer`
     processes and no `/var/run/displaycameras*` files → then start.
7. Verify: `sudo /usr/bin/displaycameras status` shows all cameras Playing
   with advancing positions; `tail /var/log/displaycameras.log` shows no
   ERROR/WARN since restart.

## Rollback

Before every sync, back up the installed files:
`sudo mkdir -p /root/dc-pre-sync-bak-<TS> && sudo cp /usr/bin/displaycameras
/usr/bin/omxplayer_dbuscontrol /usr/lib/displaycameras/*.sh
/etc/systemd/system/displaycameras.service /root/dc-pre-sync-bak-<TS>/`
To roll back: copy back, `daemon-reload`, `systemctl restart displaycameras`.

## Security notes

- Camera passwords live in `/etc/displaycameras/layout.conf.*` (root-only,
  never committed). Log lines redact userinfo via `redact_url()`
  (`rtsp://user:pass@host/...` → `rtsp://***@host/...`).
- Residual exposure that cannot be fixed in this project: `omxplayer` needs
  credentials on its command line, so `ps aux` shows them to root.
  Mitigation: use a least-privilege camera viewer account, rotate it if
  logs/process lists were ever shared.
- Old logs under `/var/log/displaycameras.log*` may still contain
  pre-redaction URLs. They rotate out in 7 days (`logrotate.conf`); do not
  copy them off the Pi.
