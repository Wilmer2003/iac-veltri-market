#!/bin/bash
# =============================================================================
# USER DATA SCRIPT PARA INSTANCIAS EC2
# =============================================================================
# Este script se ejecuta cuando inicia la instancia EC2.
# Realiza:
#   1. Instalar Docker
#   2. Instalar CloudWatch agent
#   3. Descargar imagen de ECR
#   4. Iniciar contenedor Django
#   5. Configurar logs a CloudWatch
#
# Variables inyectadas por Terraform:
#   - project_name: nombre del proyecto
#   - ecr_repository: URL del repositorio ECR
# =============================================================================

set -e  # Salir si hay error

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== USER DATA START ====="

# =============================================================================
# 1. ACTUALIZAR SISTEMA
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Actualizando sistema..."
yum update -y

# =============================================================================
# 2. INSTALAR DOCKER
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Instalando Docker..."
amazon-linux-extras install docker -y
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# =============================================================================
# 3. INSTALAR AWS CLI Y HERRAMIENTAS
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Instalando AWS CLI..."
yum install -y aws-cli jq

# =============================================================================
# 4. INSTALAR CLOUDWATCH AGENT
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Instalando CloudWatch Agent..."
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm

# Crear configuración CloudWatch Agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'EOF'
{
  "metrics": {
    "namespace": "${project_name}",
    "metrics_collected": {
      "mem": {
        "measurement": [
          {
            "name": "mem_used_percent",
            "rename": "MemoryUtilization",
            "unit": "Percent"
          }
        ],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": [
          {
            "name": "used_percent",
            "rename": "DiskUtilization",
            "unit": "Percent"
          }
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "/"
        ]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/docker-django.log",
            "log_group_name": "/aws/${project_name}/backend",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/aws/${project_name}/startup",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
EOF

# Iniciar CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a query -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s

# =============================================================================
# 5. AUTENTICAR CON ECR
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Autenticando con ECR..."

# Obtener token de autorización de ECR
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Hacer login en ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

# =============================================================================
# 6. DESCARGAR IMAGEN DE ECR
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Descargando imagen Docker de ECR..."

IMAGE_URI="${ecr_repository}:latest"

# Reintentar 3 veces por si hay fallos de red
for i in 1 2 3; do
  if docker pull $IMAGE_URI; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Imagen descargada exitosamente"
    break
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Intento $i falló, reintentando..."
  sleep 5
done

# =============================================================================
# 7. OBTENER SECRETOS DE SECRETS MANAGER
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Obteniendo credenciales de Secrets Manager..."

SECRET_NAME="${project_name}-aurora-credentials"
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id $SECRET_NAME \
  --region $AWS_REGION \
  --query SecretString \
  --output text)

# Extraer valores
DB_HOST=$(echo $SECRET_JSON | jq -r '.host')
DB_PORT=$(echo $SECRET_JSON | jq -r '.port')
DB_USER=$(echo $SECRET_JSON | jq -r '.username')
DB_PASSWORD=$(echo $SECRET_JSON | jq -r '.password')
DB_NAME=$(echo $SECRET_JSON | jq -r '.dbname')

# =============================================================================
# 8. CREAR DIRECTORIO DE LOGS
# =============================================================================
mkdir -p /var/log/docker
chown ec2-user:ec2-user /var/log/docker

# =============================================================================
# 9. EJECUTAR CONTENEDOR DJANGO
# =============================================================================
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando contenedor Django..."

docker run -d \
  --name django-app \
  --restart always \
  -p 8000:8000 \
  -e DB_HOST="$DB_HOST" \
  -e DB_PORT="$DB_PORT" \
  -e DB_USER="$DB_USER" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  -e DB_NAME="$DB_NAME" \
  -e DEBUG="False" \
  -e ENVIRONMENT="dev" \
  -v /var/log/docker/django.log:/var/log/django.log \
  --log-driver awslogs \
  --log-opt awslogs-group="/aws/${project_name}/backend" \
  --log-opt awslogs-stream="{instance_id}" \
  --log-opt awslogs-region="$AWS_REGION" \
  $IMAGE_URI

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Contenedor iniciado"

# =============================================================================
# 10. CREAR HEALTH CHECK SCRIPT
# =============================================================================
# ALB hace requests a /health/ cada 30s
# Este script verifica que Django está respondiendo

cat > /opt/health_check.sh <<'EOF'
#!/bin/bash
if curl -s http://localhost:8000/health/ > /dev/null 2>&1; then
  exit 0
else
  exit 1
fi
EOF

chmod +x /opt/health_check.sh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== USER DATA END ====="
