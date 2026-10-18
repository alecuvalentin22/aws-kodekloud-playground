# notes-api: standard library only, so there is nothing to pip install.
# Same pinned base as ci/apps/demo-api, which the playground already knows how to build.
FROM python:3.13.16-slim

ARG VERSION=dev
ENV VERSION=${VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app.py .

# Never root in the container. A numeric uid, so Kubernetes can verify
# runAsNonRoot (it cannot map a user NAME to a uid).
RUN useradd --uid 10001 --no-create-home app
USER 10001

EXPOSE 8080
CMD ["python", "app.py"]
