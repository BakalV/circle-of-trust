
FROM python:3.11-slim as builder

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock ./

RUN uv sync --frozen --no-dev

FROM gcr.io/distroless/python3-debian11

LABEL maintainer="devops@circle-of-trust.com"
LABEL description="Circle of Trust Backend API"
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION
LABEL org.opencontainers.image.created=$BUILD_DATE
LABEL org.opencontainers.image.revision=$VCS_REF
LABEL org.opencontainers.image.version=$VERSION

COPY --from=builder /app/.venv /app/.venv

COPY --chown=nonroot:nonroot backend/ /app/backend/
COPY --chown=nonroot:nonroot prompts/ /app/prompts/
COPY --chown=nonroot:nonroot data/ /app/data/

WORKDIR /app

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV ENVIRONMENT=production

USER nonroot:nonroot

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/app/.venv/bin/python", "-c", "import httpx; httpx.get('http://localhost:8001/')"]

CMD ["/app/.venv/bin/python", "-m", "backend.main"]
