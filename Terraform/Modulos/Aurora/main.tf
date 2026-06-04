# =============================================================================
# MÓDULO: Aurora MySQL — Base de Datos Multi-AZ Altamente Disponible
# =============================================================================
# Aurora es la BD de clase empresarial de AWS:
#   - Compatible con MySQL pero con 5x mejor rendimiento
#   - Replicación automática Multi-AZ (síncrona)
#   - Failover automático en < 60 segundos
#   - Backups automáticos (7 días)
#   - Snapshots (0 impacto en rendimiento)
#   - Encriptación en reposo y tránsito
#
# ARQUITECTURA:
#   Instancia Primaria (AZ-a) ←→ Instancia Réplica (AZ-b)
#   ↑ Escribe y lee                ↑ Solo lee (si fallamos)
#   Todo sincronizado
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "db_subnet_ids" {
  description = "IDs de las subredes privadas de BD (2 mínimo, 1 por AZ)"
  type        = list(string)
}

variable "db_security_group_id" {
  description = "Security group que controla acceso a Aurora"
  type        = string
}

variable "master_username" {
  description = "Usuario maestro de Aurora"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "master_password" {
  description = "Contraseña del usuario maestro (desde Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "database_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
  default     = "veltri_prod"
}

variable "instance_class" {
  description = "Clase de instancia de Aurora (db.t3.micro para DEV, db.r5.large para PROD)"
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  description = "Versión de MySQL (8.0.mysql_aurora.3.02.0, etc.)"
  type        = string
  default     = "8.0.mysql_aurora.3.02.0"
}

variable "backup_retention_days" {
  description = "Días de retención de backups automáticos (1-35)"
  type        = number
  default     = 7
}

variable "multi_az" {
  description = "Crear réplica en otra AZ (true = Multi-AZ, false = single AZ)"
  type        = bool
  default     = true
}

variable "enable_encryption" {
  description = "Cifrar datos en reposo con KMS"
  type        = bool
  default     = true
}

variable "enable_performance_insights" {
  description = "Habilitar AWS Performance Insights (para diagnóstico)"
  type        = bool
  default     = true
}

variable "enable_cloudwatch_logs" {
  description = "Enviar logs a CloudWatch"
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. DB SUBNET GROUP
# =============================================================================
# Aurora necesita estar en un "subnet group" — le decimos:
# "Aquí viven todas tus instancias" (siempre en subredes privadas)
#
# AWS usa esto para:
#   - Saber dónde crear las réplicas
#   - Failover automático entre AZs
#   - Multi-AZ deployment

resource "aws_db_subnet_group" "aurora" {
  name            = "${var.project_name}-aurora-subnet-group"
  description     = "Subnet group para Aurora MySQL — Subredes privadas de BD"
  subnet_ids      = var.db_subnet_ids
  skip_final_snapshot = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-subnet-group"
  })
}


# =============================================================================
# 2. KMS KEY PARA ENCRIPTACIÓN (OPCIONAL)
# =============================================================================
# Clave de encriptación para datos en reposo.
# Si no especificamos key_id, AWS usa su key por defecto (también está bien).

resource "aws_kms_key" "aurora_encryption" {
  count                   = var.enable_encryption ? 1 : 0
  description             = "KMS key para encriptar Aurora MySQL de ${var.project_name}"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-key"
  })
}

resource "aws_kms_alias" "aurora_encryption" {
  count         = var.enable_encryption ? 1 : 0
  name          = "alias/${var.project_name}-aurora"
  target_key_id = aws_kms_key.aurora_encryption[0].key_id
}


# =============================================================================
# 3. DB CLUSTER (El "cluster" que contiene las instancias)
# =============================================================================
# El cluster es el contenedor de todas las instancias Aurora.
# Una vez creado, agregamos instancias dentro.

resource "aws_rds_cluster" "aurora" {
  cluster_identifier              = "${var.project_name}-aurora-cluster"
  engine                          = "aurora-mysql"
  engine_version                  = var.engine_version
  database_name                   = var.database_name
  master_username                 = var.master_username
  master_password                 = var.master_password
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [var.db_security_group_id]
  
  # Backups y mantenimiento
  backup_retention_period         = var.backup_retention_days
  preferred_backup_window         = "03:00-04:00"                    # 3-4 AM UTC
  preferred_maintenance_window    = "sun:04:00-sun:05:00"           # Domingos 4-5 AM
  
  # Seguridad
  storage_encrypted               = var.enable_encryption
  kms_key_id                      = var.enable_encryption ? aws_kms_key.aurora_encryption[0].arn : null
  skip_final_snapshot             = false                            # IMPORTANTE: crear snapshot antes de eliminar
  final_snapshot_identifier       = "${var.project_name}-aurora-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  copy_tags_to_snapshot           = true
  
  # Multi-AZ y Failover
  availability_zones              = null  # Dejar que AWS lo elija automáticamente
  
  # Logs
  enabled_cloudwatch_logs_exports = var.enable_cloudwatch_logs ? ["error", "general", "slowquery"] : []
  
  # Performance Insights
  enable_performance_insights     = var.enable_performance_insights
  performance_insights_retention_period = var.enable_performance_insights ? 7 : null
  
  # Backtrack (permite volver a un punto en el tiempo, solo para MySQL 5.7+)
  backtrack_window                = 24  # Permite volver 24 horas atrás
  
  # Enablement flags
  enable_http_endpoint            = false  # Data API (no necesario para esta aplicación)
  enable_deletion_protection      = true   # Proteger contra eliminación accidental
  
  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-cluster"
    Type = "database"
  })
}


# =============================================================================
# 4. INSTANCIA AURORA PRIMARIA (AZ-a)
# =============================================================================
# La instancia que recibe escrituras y lecturas en condiciones normales.

resource "aws_rds_cluster_instance" "aurora_primary" {
  cluster_identifier           = aws_rds_cluster.aurora.id
  identifier                   = "${var.project_name}-aurora-primary"
  instance_class               = var.instance_class
  engine                       = aws_rds_cluster.aurora.engine
  engine_version               = aws_rds_cluster.aurora.engine_version
  publicly_accessible          = false                               # NUNCA públicamente accesible

  performance_insights_enabled = var.enable_performance_insights
  auto_minor_version_upgrade   = true

  monitoring_interval          = 60                                  # CloudWatch metrics cada 60s
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn
  
  # Esta es la instancia PRIMARY
  promotion_tier               = 0  # 0 = primary, 1+ = replicas

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-primary"
    Role = "primary"
  })

  depends_on = [aws_iam_role_policy.rds_monitoring]
}


# =============================================================================
# 5. INSTANCIA AURORA RÉPLICA (AZ-b)
# =============================================================================
# Réplica sincronizada en otra AZ para failover automático.
# En caso de falla de la primaria, esta se promueve automáticamente.

resource "aws_rds_cluster_instance" "aurora_replica" {
  count                        = var.multi_az ? 1 : 0
  cluster_identifier           = aws_rds_cluster.aurora.id
  identifier                   = "${var.project_name}-aurora-replica"
  instance_class               = var.instance_class
  engine                       = aws_rds_cluster.aurora.engine
  engine_version               = aws_rds_cluster.aurora.engine_version
  publicly_accessible          = false

  performance_insights_enabled = var.enable_performance_insights
  auto_minor_version_upgrade   = true

  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn
  
  # Esta es la instancia REPLICA
  promotion_tier               = 1  # Se promovería a primary si la primaria falla

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-replica"
    Role = "replica"
  })

  depends_on = [aws_iam_role_policy.rds_monitoring]
}


# =============================================================================
# 6. IAM ROLE PARA MONITORING
# =============================================================================
# Aurora necesita permisos para enviar métricas a CloudWatch.

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-rds-monitoring-role"
  })
}

resource "aws_iam_role_policy" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-policy"
  role = aws_iam_role.rds_monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogStream",
          "logs:CreateLogGroup"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}


# =============================================================================
# 7. PARAMETER GROUP (Configuración de MySQL)
# =============================================================================
# Aquí se pueden ajustar parámetros de MySQL (max_connections, timeout, etc.)
# Por ahora usamos defaults, pero puedes personalizarlos.

resource "aws_rds_cluster_parameter_group" "aurora" {
  name        = "${var.project_name}-aurora-params"
  family      = "aurora-mysql8.0"
  description = "Parameter group para Aurora MySQL del proyecto ${var.project_name}"

  # Ejemplo: configurar character set
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-params"
  })
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "cluster_id" {
  description = "Identificador del cluster Aurora"
  value       = aws_rds_cluster.aurora.id
}

output "cluster_endpoint" {
  description = "Endpoint del cluster (para escrituras)"
  value       = aws_rds_cluster.aurora.endpoint
}

output "cluster_reader_endpoint" {
  description = "Endpoint de lectura (puede ir a cualquier replica)"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "cluster_port" {
  description = "Puerto de conexión (3306 para MySQL)"
  value       = aws_rds_cluster.aurora.port
}

output "database_name" {
  description = "Nombre de la base de datos inicial"
  value       = aws_rds_cluster.aurora.database_name
}

output "master_username" {
  description = "Usuario maestro"
  value       = aws_rds_cluster.aurora.master_username
  sensitive   = true
}

output "primary_instance_id" {
  description = "ID de la instancia primaria"
  value       = aws_rds_cluster_instance.aurora_primary.id
}

output "replica_instance_id" {
  description = "ID de la instancia réplica (si Multi-AZ habilitado)"
  value       = try(aws_rds_cluster_instance.aurora_replica[0].id, "no replica")
}

output "connection_string" {
  description = "String de conexión para aplicación (usar desde Secrets Manager en producción)"
  value       = "mysql://${aws_rds_cluster.aurora.master_username}:PASSWORD@${aws_rds_cluster.aurora.endpoint}:${aws_rds_cluster.aurora.port}/${aws_rds_cluster.aurora.database_name}"
  sensitive   = true
}
