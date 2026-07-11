# jellyfin-fork

Jellyfin server overlay for multi-replica operation on Kubernetes: a pinned upstream ref plus five small patches. Migration gating, leader-gated background work, and cross-replica token validity. Pairs with [jellyfin-pgsql](https://github.com/PjSalty/jellyfin-pgsql) (PostgreSQL provider + Valkey second level cache), which carries the database side with zero server patches.

This is an overlay build, not a diverged fork: `UPSTREAM_REF` pins the upstream release, `patches/` holds the changes with intent and drop-when conditions in their messages, and CI reassembles from pristine upstream on every run. `DIVERGENCE.md` is the complete list.

## What the patches do

| Concern | Without | With |
|---|---|---|
| DB migrations | every replica races the migration path at boot | a Job runs `--mode MigrateSystem` once; replicas set `JELLYFIN_SKIP_MIGRATIONS=true` and fail fast if the schema is behind |
| Scheduled tasks, library scans, DVR | every replica arms every cron trigger and records everything N times | arm only where `JELLYFIN_ROLE=leader`; manual API-invoked runs still work anywhere |
| Auth tokens | tokens minted on one replica 401 on the others until restart | token cache misses read through to the database |
| Concurrent item saves | duplicate-key aborts on ItemValues under parallel writers | upstream PR 17119's get-or-create fix, ported to this tag |

Unset `JELLYFIN_ROLE` and everything behaves exactly like stock Jellyfin: the gates only close when you opt a pod into being a follower.

## Build

```bash
./build/assemble.sh
docker build -f docker/Dockerfile -t jellyfin-fork:local .
```

The image compiles the patched server and overlays the binaries onto the official image, keeping its web client and ffmpeg.

## Credits and license

The server is Jellyfin's, the ideas for most patches come from upstream PRs, and the intent is to keep offering the generally useful ones back. GPL-2.0, same as upstream.
