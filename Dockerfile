# syntax=docker/dockerfile:1
FROM python:3.12.12-slim-bookworm

ARG APP_VERSION=local
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HOST=0.0.0.0 \
    PORT=8000 \
    APP_VERSION=${APP_VERSION}
LABEL org.opencontainers.image.title="kakao-chat-analyzer" \
      org.opencontainers.image.revision="${APP_VERSION}"

WORKDIR /service
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser

COPY app/ ./app/
COPY static/ ./static/
COPY run.py ./

USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=15s --retries=3 \
    CMD python -c "import json, urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2); assert r.status == 200 and json.load(r)['status'] == 'ok'"
CMD ["python", "run.py"]
