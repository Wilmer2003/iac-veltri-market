# =============================================================================
# MÓDULO: Secrets Manager — Gestión de Credenciales
# =============================================================================
# Gestiona secretos como credenciales de base de datos, keys de API, etc.
# con rotación automática cada 90 días.
#
# PRINCIPIO DE MÍNIMO PRIVILEGIO:
#   Las credenciales NUNCA se escriben en código o variables.tf
#   Se generan automáticamente y se guardan encriptadas en AWS Secrets Manager.
#   Solo el servicio que lo necesita (EC2, Lambda) puede leerlo.
#
# ROTACIÓN AUTOMÁTICA:
#   Lambda se ejecuta cada 90 días y genera una nueva contraseña
#   sin interrumpir la conexión actual.
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "common_tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
}

# Aurora database details
variable "aurora_endpoint" {
  description = "Endpoint de Aurora RDS"
  type        = string
}

variable "aurora_port" {
  description = "Puerto de Aurora (default 3306 para MySQL)"
  type        = number
  default     = 3306
}

variable "aurora_username" {
  description = "Usuario maestro de Aurora"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "aurora_db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "veltri_prod"
}


# =============================================================================
# 1. GENERAR CONTRASEÑA ALEATORIA
# =============================================================================
# Terraform genera automáticamente una contraseña segura (32 caracteres)
# con mayúsculas, minúsculas, números y caracteres especiales.

resource "random_password" "aurora_password" {
  length      = 32
  special     = true
  min_upper   = 5
  min_lower   = 5
  min_numeric = 5
  min_special = 3

  # Excluir caracteres que pueden causar problemas en URLs o shells
  override_special = "!#$%&*()-_=+[]{}<>:?"
}


# =============================================================================
# 2. SECRETO DE AURORA EN SECRETS MANAGER
# =============================================================================
# Almacena las credenciales de Aurora en formato JSON encriptado.
# AWS cifra el secreto con KMS (encryption key) automáticamente.
#
# Ejemplo de contenido:
# {
#   "username": "admin",
#   "password": "Agl2K8dP9xQ1mN4wL6sJ3vH5bC7fD2eR8tY0uI",
#   "engine": "mysql",
#   "host": "veltri-dev-aurora-cluster.cxxxxxx.us-east-1.rds.amazonaws.com",
#   "port": 3306,
#   "dbname": "veltri_prod"
# }
# =============================================================================

resource "aws_secretsmanager_secret" "aurora_credentials" {
  name                    = "${var.project_name}-aurora-credentials"
  description             = "Credenciales de base de datos Aurora MySQL para ${var.project_name}"
  recovery_window_in_days = 7  # Si se intenta borrar, se puede recuperar en 7 días

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-credentials"
    Type = "database"
  })
}

# Valor secreto en formato JSON
resource "aws_secretsmanager_secret_version" "aurora_credentials" {
  secret_id = aws_secretsmanager_secret.aurora_credentials.id
  secret_string = jsonencode({
    username = var.aurora_username
    password = random_password.aurora_password.result
    engine   = "mysql"
    host     = var.aurora_endpoint
    port     = var.aurora_port
    dbname   = var.aurora_db_name
  })
}


# =============================================================================
# 3. LAMBDA PARA ROTACIÓN AUTOMÁTICA (OPCIONAL)
# =============================================================================
# Función Lambda que se ejecuta cada 90 días para cambiar la contraseña.
# Por ahora, lo dejamos comentado — se implementará en Semana 5.
#
# En producción:
#   - Lambda cambia la contraseña en Aurora
#   - Actualiza el secreto en Secrets Manager
#   - Todo esto sin downtime
# =============================================================================

# TODO: Descomentar cuando exista el módulo lambda
# resource "aws_secretsmanager_secret_rotation" "aurora_rotation" {
#   secret_id           = aws_secretsmanager_secret.aurora_credentials.id
#   rotation_rules {
#     automatically_after_days = 90
#   }
#   rotation_lambda_arn = module.lambda_rotation.function_arn
# }


# =============================================================================
# 4. POLÍTICA DE LECTURA DEL SECRETO
# =============================================================================
# Esta política permite que EC2 e IAM roles específicos lean el secreto.
# Se referencia desde el módulo EC2 o Lambda cuando lo necesite.

resource "aws_secretsmanager_secret_policy" "aurora_read_policy" {
  secret_id = aws_secretsmanager_secret.aurora_credentials.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadFromServices"
        Effect = "Allow"
        Principal = {
          Service = [
            "ec2.amazonaws.com",
            "lambda.amazonaws.com"
          ]
        }
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.aurora_credentials.arn
      }
    ]
  })
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "secret_id" {
  description = "ID del secreto en Secrets Manager (para referenciar en otros módulos)"
  value       = aws_secretsmanager_secret.aurora_credentials.id
}

output "secret_arn" {
  description = "ARN del secreto (para políticas IAM)"
  value       = aws_secretsmanager_secret.aurora_credentials.arn
}

output "secret_version_id" {
  description = "Versión actual del secreto"
  value       = aws_secretsmanager_secret_version.aurora_credentials.version_id
  sensitive   = true
}

output "aurora_password" {
  description = "Contraseña generada para Aurora (GUARDAR EN LUGAR SEGURO)"
  value       = random_password.aurora_password.result
  sensitive   = true
}
