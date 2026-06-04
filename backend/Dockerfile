# syntax=docker/dockerfile:1

# =============================================================================
# DOCKERFILE — Imagen Docker para Veltri Minimarket Backend
# =============================================================================
# Build stage: compilar dependencias
# Runtime stage: ejecutar aplicación
#
# Usa multi-stage para reducir tamaño de imagen final
# =============================================================================

# =============================================================================
# STAGE 1: Builder — Compilar dependencias Python
# =============================================================================
FROM python:3.11-slim as builder

WORKDIR /app

# Instalar herramientas de build (necesarias para compilar algunos paquetes)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Copiar requirements y instalar dependencias
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt


# =============================================================================
# STAGE 2: Runtime — Imagen final
# =============================================================================
FROM python:3.11-slim

WORKDIR /app

# Instalar solo runtime dependencies (no herramientas de build)
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Crear usuario no-root (buena práctica de seguridad)
RUN useradd -m -u 1000 appuser

# Copiar dependencias compiladas desde stage 1
COPY --from=builder /root/.local /home/appuser/.local
ENV PATH=/home/appuser/.local/bin:$PATH

# Copiar código de aplicación
COPY . .

# Cambiar propietario de archivos
RUN chown -R appuser:appuser /app

# Cambiar a usuario no-root
USER appuser

# Crear directorio de logs
RUN mkdir -p /var/log/django

# Health check (verifica que la aplicación está respondiendo)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/health/ || exit 1

# Exponer puerto 8000 (Gunicorn)
EXPOSE 8000

# Comando para ejecutar la aplicación
# Usa Gunicorn como servidor WSGI (4 workers por defecto)
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "4", \
     "--worker-class", "sync", \
     "--worker-tmp-dir", "/dev/shm", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--log-level", "info", \
     "project.wsgi:application"]
