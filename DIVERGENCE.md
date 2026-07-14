# Divergence from upstream

Everything this repo changes relative to [jellyfin/jellyfin](https://github.com/jellyfin/jellyfin) at the ref pinned in `UPSTREAM_REF`. The list is the contract: if it's not here, we didn't change it.

| Patch | What | Drop when |
|---|---|---|
| `0001-startup-backport-the-MigrateSystem-and-SeedSystem-mo.patch` | backport of upstream PR 16319: `--mode MigrateSystem\|SeedSystem` run-and-exit modes, the hook for a single-writer migration Job | UPSTREAM_REF moves to a base containing PR 16319 |
| `0002-migrations-skip-gate-for-replica-processes.patch` | migration skip-gate: `JELLYFIN_SKIP_MIGRATIONS=true` fails fast on pending migrations instead of racing N replicas through them | upstream grows an equivalent |
| `0003-items-make-the-ItemValues-get-or-create-concurrency-.patch` | port of upstream PR 17119: ItemValues get-or-create made concurrency-safe under parallel item saves | UPSTREAM_REF contains PR 17119 (lands in the ItemPersistenceService refactor line) |
| `0004-replication-leader-gate-background-work.patch` | leader gating: scheduled task triggers, trigger-originated scans, and LiveTV/DVR timer arming run only where `JELLYFIN_ROLE` is unset or `leader` | upstream ships first-class multi-instance roles |
| `0005-devices-read-through-to-the-database-on-token-cache-.patch` | device token read-through: token cache misses re-check the database before rejecting, so tokens minted by another replica work | upstream makes the token path DB-backed |
| `0006-users-delete-permissions-and-preferences-on-update-in.patch` | `UpdateUserAsync` deletes the user's old Permissions/Preferences instead of orphaning them. `Permission.UserId` is `Guid?` (optional), so `Clear()` makes EF *sever* (`SET "UserId" = NULL`) rather than delete; every call stranded 24+13 unreachable rows. Upstream bug, not multi-replica-specific: SQLite installs leak the same rows | upstream fixes it (report/PR filed) |

Image-layer divergence (no server patch involved):

| Layer | What | Drop when |
|---|---|---|
| rffmpeg dispatch shims | [rffmpeg](https://github.com/joshuaboniface/rffmpeg) pinned by commit + checksum (no upstream releases), installed as `ffmpeg-dispatch`/`ffprobe-dispatch` with a baked `/etc/rffmpeg/rffmpeg.yml`; routes encodes to an ssh worker with local fallback | Jellyfin grows native remote transcoding |

Ceilings worth knowing:

- Single-node behavior is unchanged by construction: every gate defaults open when `JELLYFIN_ROLE` is unset, the skip-gate only acts when its env var is set, and the dispatch shims sit unused until the encoder path is pointed at them. A stock deployment of this image behaves like the official one.
- The image build compiles the server but keeps the official image's jellyfin-web and jellyfin-ffmpeg; a web or ffmpeg change upstream arrives via the base image bump, not this repo.
- The dispatch path is single-worker with local fallback, not worker HA: rffmpeg load-balances across registered hosts, but this repo's smoke only proves one worker plus fallback. Register more hosts if you need spread.
- Builds carry `-p:NoWarn=CA1707` until UPSTREAM_REF passes upstream's own rename of two migration class names (same story as the sibling plugin repo).
