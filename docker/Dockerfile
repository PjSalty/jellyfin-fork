# Builds the patched server and overlays ONLY the server binaries onto the
# official image, keeping its jellyfin-web and jellyfin-ffmpeg untouched.
# Build context is the repo root with the assembled tree at upstream/
# (see build/assemble.sh).
ARG BASE_IMAGE=jellyfin/jellyfin:10.11.11
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:9.0

FROM ${SDK_IMAGE} AS build
WORKDIR /src
COPY upstream/ .
# Self-contained linux-x64, matching how the official image ships: the base
# carries no dotnet runtime, so a framework-dependent publish dies at launch
# with 'Failed to resolve libhostfxr.so'.
# NoWarn=CA1707 mirrors upstream's own state at this tag (migration class
# names, renamed after the tag); drop the suppression when UPSTREAM_REF
# moves past the rename.
RUN dotnet publish Jellyfin.Server/Jellyfin.Server.csproj \
    -c Release \
    --runtime linux-x64 \
    --self-contained true \
    -p:NoWarn=CA1707 \
    -p:DebugSymbols=false -p:DebugType=none \
    -o /out

FROM ${BASE_IMAGE}
# Pull the distro security point releases the base predates (the release
# Trivy gate fails on fixed-but-unpatched HIGHs otherwise), and install the
# postgres client tools: the PG provider plugin shells out to pg_dump for
# its pre-migration backups, so the migrate pass dies without them (same
# lesson as the sibling plugin image). PGDG repo because the client major
# must be >= the PostgreSQL server major (16); https sources because build
# environments commonly block plain http egress.
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
       -o /usr/share/keyrings/pgdg.asc \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "${VERSION_CODENAME}")-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-16 \
    && rm -rf /var/lib/apt/lists/*

# The official image keeps the server in /jellyfin with web at
# /jellyfin/jellyfin-web; replace the server payload, preserve the web client.
RUN mv /jellyfin/jellyfin-web /tmp/jellyfin-web-keep \
    && rm -rf /jellyfin \
    && mkdir /jellyfin \
    && mv /tmp/jellyfin-web-keep /jellyfin/jellyfin-web
COPY --from=build /out/ /jellyfin/
