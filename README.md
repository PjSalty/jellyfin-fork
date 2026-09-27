# jellyfin-fork

Jellyfin server overlay for multi-replica operation on Kubernetes: a pinned upstream release (currently v12.1) plus a short series of patches. Migration gating, leader-gated background work, cross-replica token validity, conflict-safe concurrent writes, and PostgreSQL-safe versions of the upstream migrations that only ran on SQLite. Pairs with [jellyfin-pgsql](https://github.com/PjSalty/jellyfin-pgsql) (PostgreSQL provider + Valkey second level cache), which carries the database side with zero server patches.

This is an overlay build, not a diverged fork: `UPSTREAM_REF` pins the upstream release, `patches/` holds the changes with intent and drop-when conditions in their messages, and CI reassembles from pristine upstream on every run. `DIVERGENCE.md` is the complete list.

## What the patches do

| Concern | Without | With |
|---|---|---|
| DB migrations | every replica races the migration path at boot | a Job runs `--mode MigrateSystem` once; replicas set `JELLYFIN_SKIP_MIGRATIONS=true` and fail fast if the schema is behind |
| Scheduled tasks, library scans, DVR | every replica arms every cron trigger and records everything N times | arm only where `JELLYFIN_ROLE=leader`; manual API-invoked runs still work anywhere |
| Auth tokens | tokens minted on one replica 401 on the others until restart | token cache misses read through to the database |
| Concurrent saves | duplicate-key aborts on ItemValues, BaseItemProviders and UserData under parallel writers (HTTP 500 on playback progress) | conflict-safe upserts, so concurrent writers converge |
| Upgrading an existing database | two 12.1 migrations use SQLite-only SQL or a second command on an open reader, and fail the migration Job on PostgreSQL | provider-neutral rewrites of both |
| Paging a library | items that share a sort name come back in a different order on each page under PostgreSQL, so paged lists repeat some items and skip others | every item ordering ends on the item id, so pages are stable |

Unset `JELLYFIN_ROLE` and everything behaves exactly like stock Jellyfin: the gates only close when you opt a pod into being a follower.

## Remote transcoding (optional)

The image bundles [rffmpeg](https://github.com/joshuaboniface/rffmpeg) (pinned by commit and checksum, since upstream tags no releases) as `ffmpeg-dispatch` / `ffprobe-dispatch`. Point Jellyfin's ffmpeg path at `/usr/local/bin/ffmpeg-dispatch` and encodes run on a remote worker over ssh, with the serving pod's own jellyfin-ffmpeg as automatic fallback: one GPU box can serve every replica, and losing it costs performance, never playback.

To wire it up: mount a client key and `known_hosts` at `/etc/rffmpeg/ssh/`, run `rffmpeg init -y && rffmpeg add <worker>` once per container (an initContainer in Kubernetes), and run sshd on the worker for user `rffmpeg` on port 2222 with jellyfin-ffmpeg at its standard path (`tests/worker/` is a working reference). Baked defaults live in `docker/rffmpeg.yml`; mount your own file over it to change them. Don't touch any of this and the image encodes locally, exactly like stock.

## Build

```bash
./build/assemble.sh
docker build -f docker/Dockerfile -t jellyfin-fork:local .
```

The image compiles the patched server and overlays the binaries onto the official image, keeping its web client and ffmpeg.

`./tests/smoke.sh` runs the migrate Job, a leader and a replica against PostgreSQL 18 with the [jellyfin-pgsql](https://github.com/PjSalty/jellyfin-pgsql) release named by `JELLYFIN_PGSQL_VERSION`; set `JELLYFIN_PGSQL_LOCAL_DIR` to a directory holding a release zip and its `SHA256SUMS` to smoke a plugin build before it is published.

## Credits and license

The server is Jellyfin's, the ideas for most patches come from upstream PRs, and the intent is to keep offering the generally useful ones back. GPL-2.0, same as upstream.
