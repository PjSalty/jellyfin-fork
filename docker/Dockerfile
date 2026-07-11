# Builds the patched server and overlays ONLY the server binaries onto the
# official image, keeping its jellyfin-web and jellyfin-ffmpeg untouched.
# Build context is the repo root with the assembled tree at upstream/
# (see build/assemble.sh).
ARG BASE_IMAGE=jellyfin/jellyfin:10.11.11
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:9.0

FROM ${SDK_IMAGE} AS build
WORKDIR /src
COPY upstream/ .
# NoWarn=CA1707 mirrors upstream's own state at this tag (migration class
# names, renamed after the tag); drop with the suppression in CI when
# UPSTREAM_REF moves past the rename.
RUN dotnet publish Jellyfin.Server/Jellyfin.Server.csproj \
    -c Release \
    -p:NoWarn=CA1707 \
    -p:DebugSymbols=false -p:DebugType=none \
    -o /out

FROM ${BASE_IMAGE}
# The official image keeps the server in /jellyfin with web at
# /jellyfin/jellyfin-web; replace the server payload, preserve the web client.
RUN mv /jellyfin/jellyfin-web /tmp/jellyfin-web-keep \
    && rm -rf /jellyfin \
    && mkdir /jellyfin \
    && mv /tmp/jellyfin-web-keep /jellyfin/jellyfin-web
COPY --from=build /out/ /jellyfin/
