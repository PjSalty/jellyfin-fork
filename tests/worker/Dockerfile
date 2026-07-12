# Test fixture: a GPU-less stand-in for a transcode worker. Same contract a
# real worker exposes (key-only sshd on 2222, an rffmpeg login user, and
# jellyfin-ffmpeg at the standard path); CPU encode only, which is all a CI
# smoke needs to prove the dispatch path.
FROM jellyfin/jellyfin:10.11.11
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && useradd -m -d /home/rffmpeg -s /bin/sh rffmpeg
COPY sshd_config /etc/ssh/sshd_config.d/rffmpeg.conf
EXPOSE 2222
ENTRYPOINT []
CMD ["/usr/sbin/sshd", "-D", "-e"]
