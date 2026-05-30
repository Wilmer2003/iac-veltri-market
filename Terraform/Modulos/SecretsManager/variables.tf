# =============================================================================
# VARIABLES: Módulo SecretsManager
# =============================================================================

variable "project_name" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

variable "aws_region" {
  description = "Región AWS donde se despliega."
  type        = string
  default     = "us-east-1"
}

# -----------------------------------------------------------------------------
# Variables de red — vienen del módulo VPC
# -----------------------------------------------------------------------------

variable "private_db_subnet_ids" {
  description = "Subredes privadas de BD para que la Lambda de rotación acceda a Aurora."
  type        = list(string)
}

variable "sg_aurora_id" {
  description = "Security Group de Aurora — la Lambda de rotación necesita este SG para conectarse."
  type        = string
}

# -----------------------------------------------------------------------------
# Variables de credenciales — vienen del entorno (DEV/PROD)
# Marcadas como sensitive para que Terraform no las muestre en logs
# -----------------------------------------------------------------------------

variable "db_master_username" {
  description = "Usuario administrador de Aurora."
  type        = string
  sensitive   = true
}

variable "db_master_password" {
  description = "Contraseña inicial de Aurora. Después la rota Secrets Manager automáticamente."
  type        = string
  sensitive   = true
}

variable "redis_auth_token" {
  description = "Token de autenticación para Redis ElastiCache."
  type        = string
  sensitive   = true
  default     = "token-placeholder-semana5"  # Se actualiza en Semana 5
}

# -----------------------------------------------------------------------------
# Variables de conexión a Aurora — vienen del módulo Aurora
# -----------------------------------------------------------------------------

variable "aurora_writer_endpoint" {
  description = "Endpoint de escritura de Aurora. Viene del output del módulo Aurora."
  type        = string
}

variable "aurora_port" {
  description = "Puerto de Aurora (3306). Viene del output del módulo Aurora."
  type        = number
  default     = 3306
}

variable "database_name" {
  description = "Nombre de la base de datos Aurora."
  type        = string
  default     = "veltri_db"
}

variable "redis_host" {
  description = "Host de Redis ElastiCache. Se completa en Semana 5."
  type        = string
  default     = "placeholder-semana5"
}

# -----------------------------------------------------------------------------
# Variables de cifrado — viene del módulo Aurora
# -----------------------------------------------------------------------------

variable "kms_key_arn" {
  description = "ARN de la clave KMS para cifrar los secretos. Viene del output del módulo Aurora."
  type        = string
}
