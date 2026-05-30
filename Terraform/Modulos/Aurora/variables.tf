# =============================================================================
# VARIABLES: Módulo Aurora
# =============================================================================
# Parámetros que recibe el módulo Aurora desde el entorno (Dev/Prod).
# Los valores sensibles como contraseñas NUNCA tienen default aquí —
# deben venir de Secrets Manager o de variables de entorno seguras.
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto. Se usa como prefijo en todos los recursos."
  type        = string
}

variable "common_tags" {
  description = "Tags comunes para todos los recursos."
  type        = map(string)
}

# -----------------------------------------------------------------------------
# Variables de red — vienen del módulo VPC
# -----------------------------------------------------------------------------

variable "private_db_subnet_ids" {
  description = "Lista de IDs de las subredes privadas de BD (Subredes 5 y 6 del diagrama). Viene del output del módulo VPC."
  type        = list(string)
}

variable "sg_aurora_id" {
  description = "ID del Security Group de Aurora. Solo permite conexiones desde EC2. Viene del módulo Seguridad."
  type        = string
}

variable "availability_zones" {
  description = "Lista de zonas de disponibilidad para el cluster Aurora."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "az_a" {
  description = "Primera zona de disponibilidad (nodo primario)."
  type        = string
  default     = "us-east-1a"
}

variable "az_b" {
  description = "Segunda zona de disponibilidad (nodo réplica)."
  type        = string
  default     = "us-east-1b"
}

# -----------------------------------------------------------------------------
# Variables de la base de datos
# -----------------------------------------------------------------------------

variable "database_name" {
  description = "Nombre de la base de datos inicial que Aurora crea automáticamente."
  type        = string
  default     = "veltri_db"
}

variable "db_master_username" {
  description = "Usuario administrador de Aurora. NO usar 'root' ni 'admin' — son nombres reservados en AWS."
  type        = string
  default     = "veltri_admin"
}

variable "db_master_password" {
  description = "Contraseña del administrador de Aurora. Viene de Secrets Manager — NUNCA escribir aquí directamente."
  type        = string
  sensitive   = true  # sensitive=true hace que Terraform NO muestre este valor en los logs
}

variable "db_instance_class" {
  description = "Tipo de instancia de Aurora. En DEV usar db.t3.micro (barato). En PROD usar db.t3.medium o mayor."
  type        = string
  default     = "db.t3.medium"
}

# -----------------------------------------------------------------------------
# Variable de cifrado KMS
# -----------------------------------------------------------------------------

variable "kms_key_arn" {
  description = "ARN de la clave KMS para cifrar Aurora. Si está vacío, el módulo crea su propia clave."
  type        = string
  default     = ""  # Si está vacío, se usa la clave que crea el propio módulo (aws_kms_key.aurora)
}
