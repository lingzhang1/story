# Story API container image.
#
# Multi-stage: build deps in one stage, copy only the runtime artifact to
# the final stage (04-aws-infrastructure.md §43). The SAME app runs
# locally, in this container, and on AWS App Runner — no AWS-specific code
# in the engines.
#
# Build context is the REPO ROOT (so packages/ and contracts/ are copyable):
#   docker build -f apps/api/Dockerfile -t story-api .

# ---- builder ------------------------------------------------------------
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /install

# Install runtime dependencies into an isolated prefix we can copy over.
RUN pip install --prefix=/install/deps \
    "fastapi" \
    "uvicorn[standard]" \
    "pydantic>=2"

# ---- runtime ------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app:/app/packages:/app/apps/api

WORKDIR /app

# Copy installed dependencies from the builder stage.
COPY --from=builder /install/deps /usr/local

# Copy only what the service needs at runtime: the engine packages, the
# contracts, and the API app. (Specs, iOS, CDK, Figma are excluded via
# .dockerignore.)
COPY packages/ /app/packages/
COPY contracts/ /app/contracts/
COPY apps/api/ /app/apps/api/

EXPOSE 8080

# Health check hits the same /health endpoint App Runner will use.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--app-dir", "/app/apps/api"]
