# Pinned base, non-root, no build tools in the final image.
FROM python:3.13.16-slim

ARG VERSION=dev
ENV VERSION=${VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Never run as root in the container. uid 10001 so it cannot collide with a
# real user on the node if a volume is ever mounted.
RUN useradd --uid 10001 --no-create-home app
USER 10001

EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
