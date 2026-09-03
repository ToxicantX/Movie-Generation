FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ffmpeg libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir edge-tts==7.2.8 opencv-python-headless==4.12.0.88 "psycopg[binary]==3.2.10" redis==6.4.0

WORKDIR /app
COPY . .

EXPOSE 8200
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=4 \
    CMD curl --fail --silent http://127.0.0.1:8200/api/health || exit 1

CMD ["python", "console/server.py", "--host", "0.0.0.0", "--port", "8200"]
