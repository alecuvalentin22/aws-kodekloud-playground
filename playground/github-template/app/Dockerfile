# Pinned base, non-root, no build tools in the final image.
FROM python:3.13.16-slim

# Links the GHCR package to this repository (and so to its visibility and to
# what its GITHUB_TOKEN may push). Without it the package is an orphan.
LABEL org.opencontainers.image.source="https://github.com/__OWNER__/__REPO__"

ARG VERSION=dev
ENV VERSION=${VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY service/app.py .

# Never run as root in the container.
RUN useradd --uid 10001 --no-create-home app
USER 10001

EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
