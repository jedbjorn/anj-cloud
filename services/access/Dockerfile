FROM python:3.14.10-slim-bookworm@sha256:516b51cb9db2ef061e465c803e50f64361b82cefd91e525b889b967b83e83527
WORKDIR /app
COPY services/access/requirements.txt /app/requirements.txt
RUN python -m pip --isolated install --no-cache-dir --disable-pip-version-check --index-url https://pypi.org/simple -r requirements.txt
# Non-root gateway (M5); under rootless Docker uid 10001 maps to a host subuid >= 100000.
# /var/lib/anj stays root-owned as before so the dev stack (container root) is unchanged;
# production's one-shot init hands its state volume to uid 10001.
RUN groupadd --system --gid 10001 anj \
 && useradd --system --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin anj \
 && install -d -o 0 -g 0 -m 0700 /var/lib/anj \
 && install -d -o 10001 -g 10001 -m 0500 /run/anj-tls \
 && install -d -o 10001 -g 10001 -m 0750 /run/anj-cloud-gw
COPY services/access /app/access
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 10001:10001
CMD ["python", "-m", "access.server"]
