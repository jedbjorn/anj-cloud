# Media fetch worker (spec #42 F1): yt-dlp with ffmpeg/ffprobe and the JavaScript runtime it needs,
# isolated from every other service. Every input is pinned: images by digest, the baseline yt-dlp by
# release tag and SHA-256. Newer yt-dlp releases go to the worker's own tools volume through
# yt-dlp's updater (stable channel, checksum-verified); the baseline here is the floor.
#
# The same image runs two services: `fetch-net` (root with only NET_ADMIN, applies the network guard
# in the shared network namespace, then sleeps) and `fetch` (uid 10003, no capabilities).

# Static ffmpeg/ffprobe 9.0.2 (https://github.com/wader/static-ffmpeg).
FROM mwader/static-ffmpeg:9.0.2-1@sha256:f5d100184884eb3e82b0eb14bb5ebf98da99826ac824989720297fb9ef21c822 AS ffmpeg
# Deno 2.9.8, the JavaScript runtime yt-dlp enables by default (EJS, yt-dlp >= 2025.11.12; deno >= 2.3).
FROM denoland/deno:bin-2.9.8@sha256:b507583d3c68ba69f3ed2ce5969ae5b8b70f43421c781279c7aea06435263543 AS deno

FROM python:3.14.10-slim-bookworm@sha256:516b51cb9db2ef061e465c803e50f64361b82cefd91e525b889b967b83e83527
ARG YTDLP_VERSION=2026.10.26
ARG YTDLP_SHA256=e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3
# nftables only for the guard service (fetch-net). Not pinned to a package version: Debian drops
# superseded versions, which would break the build; the base image is pinned by digest.
RUN apt-get update \
 && apt-get install --no-install-recommends -y nftables \
 && rm -rf /var/lib/apt/lists/*
COPY --from=ffmpeg /ffmpeg /ffprobe /usr/local/bin/
COPY --from=deno /deno /usr/local/bin/deno
# The baseline yt-dlp zipapp (official release asset; Python 3.11+), verified before it is kept.
RUN python -I -c "import hashlib,sys,urllib.request; data=urllib.request.urlopen('https://github.com/yt-dlp/yt-dlp/releases/download/' + sys.argv[1] + '/yt-dlp', timeout=120).read(); assert hashlib.sha256(data).hexdigest() == sys.argv[2], 'yt-dlp checksum mismatch'; open('/tmp/yt-dlp', 'wb').write(data)" "$YTDLP_VERSION" "$YTDLP_SHA256" \
 && install -d -m 0755 /opt/anj-fetch/baseline \
 && install -m 0644 /tmp/yt-dlp /opt/anj-fetch/baseline/yt-dlp \
 && rm /tmp/yt-dlp \
 && printf '%s\n' "$YTDLP_VERSION" > /opt/anj-fetch/baseline/VERSION
# The worker user (10003) and the spool group shared with the gateway user (10004). The spool's
# mount point is deliberately absent from the image: the gateway owns its layout. The tools volume
# (writable yt-dlp copy, its cache) starts from this directory's owner and mode.
RUN groupadd --system --gid 10004 anj-spool \
 && useradd --system --uid 10003 --gid 10004 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin anj-fetch \
 && install -d -o 10003 -g 10004 -m 0700 /var/lib/anj-fetch-tools
COPY services/fetch/*.py /opt/anj-fetch/
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 HOME=/tmp
USER 10003:10004
CMD ["python", "-I", "/opt/anj-fetch/worker.py"]
