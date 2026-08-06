# Etapa 1: construir únicamente las dependencias.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Estas capas solo cambian cuando cambian las dependencias.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# El código se copia después para aprovechar la caché anterior.
COPY app ./app


# Etapa 2: imagen final, pequeña y sin herramientas de build.
FROM python:3.12-slim

WORKDIR /app

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# Crear una identidad sin privilegios administrativos.
RUN addgroup --system app && adduser --system --ingroup app app

# Solo se toma el entorno virtual ya instalado del builder.
COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --chown=app:app app ./app

EXPOSE 8000

# Liveness: valida que la API responda, sin depender de Postgres.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz')" || exit 1

USER app

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
