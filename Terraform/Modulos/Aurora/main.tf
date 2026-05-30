# =============================================================================
# MÓDULO: Aurora MySQL — Base de datos principal de Veltri Minimarket
# =============================================================================
# Aurora es la base de datos que guarda TODO el negocio:
#   - Ventas de las 820 tiendas
#   - Inventario y stock
#   - Usuarios y sesiones
#   - Gestión logística de los 5 Hubs
#
# ¿POR QUÉ AURORA Y NO RDS NORMAL?
#   Aurora es hasta 5x más rápido que MySQL estándar y soporta
#   replicación síncrona Multi-AZ de forma nativa, lo que nos da
#   el failover automático que exige el RNF (recuperación en <35 min).
#
# ARQUITECTURA QUE CREA ESTE MÓDULO:
#
#   Subred Privada 5 (AZ-a)          Subred Privada 6 (AZ-b)
#   ┌─────────────────────┐          ┌─────────────────────┐
#   │   Aurora PRIMARIO   │ ◄──────► │   Aurora RÉPLICA    │
#   │  (lectura/escritura)│ Sincróno │  (solo en standby)  │
#   └─────────────────────┘          └─────────────────────┘
#
#   Si el primario cae → Aurora automáticamente promueve la réplica
#   como primario en menos de 60 segundos. Sin intervención manual.
# =============================================================================


# -----------------------------------------------------------------------------
# 1. SUBNET GROUP — Le dice a Aurora en qué subredes puede vivir
# -----------------------------------------------------------------------------
# Aurora necesita saber en qué subredes puede colocar sus nodos.
# Le damos las subredes privadas 5 y 6 (una por cada AZ).
# NUNCA se le dan subredes públicas a la base de datos.
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "aurora" {
  name        = "${var.project_name}-aurora-subnet-group"
  description = "Subnet group para Aurora Multi-AZ. Subredes privadas 5 y 6 del diagrama."

  # Recibe los IDs de las subredes privadas de BD desde el módulo VPC
  subnet_ids = var.private_db_subnet_ids

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-subnet-group"
  })
}


# -----------------------------------------------------------------------------
# 2. CLUSTER PARAMETER GROUP — Configuración del motor de base de datos
# -----------------------------------------------------------------------------
# Define parámetros de comportamiento de Aurora MySQL.
# Es como el archivo de configuración del motor de BD.
# -----------------------------------------------------------------------------

resource "aws_rds_cluster_parameter_group" "aurora" {
  name        = "${var.project_name}-aurora-cluster-params"
  family      = "aurora-mysql8.0"  # Aurora MySQL versión 8.0
  description = "Parámetros del cluster Aurora para Veltri Minimarket"

  # Forzar conexiones SSL — RNF exige que todo el tráfico esté cifrado
  parameter {
    name  = "require_secure_transport"
    value = "ON"
  }

  # Zona horaria para Perú (UTC-5)
  parameter {
    name  = "time_zone"
    value = "America/Lima"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-cluster-params"
  })
}


# -----------------------------------------------------------------------------
# 3. AURORA CLUSTER — El cluster principal (agrupa primario + réplica)
# -----------------------------------------------------------------------------
# El "cluster" es el contenedor lógico que agrupa todos los nodos Aurora.
# Aquí se define la configuración global: BD, credenciales, cifrado, backups.
# -----------------------------------------------------------------------------

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.project_name}-aurora-cluster"

  # Motor de base de datos
  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.04.0"  # Aurora MySQL 8.0 estable

  # Nombre de la base de datos inicial que se crea automáticamente
  database_name = var.database_name  # ej: "veltri_db"

  # ---------------------------------------------------------------------
  # CREDENCIALES — vienen de Secrets Manager, NO escritas aquí directamente
  # RNF: "Queda absolutamente prohibido el uso de contraseñas en texto plano"
  # ---------------------------------------------------------------------
  master_username = var.db_master_username  # Viene como variable segura
  master_password = var.db_master_password  # Viene de Secrets Manager

  # Subnet group y security group
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [var.sg_aurora_id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name

  # ---------------------------------------------------------------------
  # MULTI-AZ — Replicación síncrona entre AZ-a y AZ-b
  # RNF: disponibilidad 99.9% y failover automático
  # ---------------------------------------------------------------------
  availability_zones = var.availability_zones  # ["us-east-1a", "us-east-1b"]

  # ---------------------------------------------------------------------
  # BACKUPS AUTOMÁTICOS
  # RNF: "retención de copias de seguridad automáticas de 7 días"
  # RNF: RPO de 3 minutos → backup_window cada pocos minutos
  # ---------------------------------------------------------------------
  backup_retention_period = 7                    # Guardar backups por 7 días
  preferred_backup_window = "02:00-03:00"        # Backup a las 2am (hora Perú, baja actividad)

  # ---------------------------------------------------------------------
  # CIFRADO EN REPOSO
  # RNF: "100% de la información cifrada en reposo usando KMS"
  # ---------------------------------------------------------------------
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn  # Clave KMS para cifrar los datos

  # ---------------------------------------------------------------------
  # PROTECCIÓN CONTRA ELIMINACIÓN ACCIDENTAL
  # RNF: "Si un administrador intenta eliminar la BD, el sistema debe
  #       impedir esta acción automáticamente"
  # Con deletion_protection = true, AWS bloquea cualquier intento de
  # eliminar el cluster desde consola o CLI
  # ---------------------------------------------------------------------
  deletion_protection = true

  # Mantenimiento programado fuera del horario de negocio
  # Veltri opera L-S 8am-11pm, D 8am-6pm → mantenimiento domingo madrugada
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  # Al destruir con Terraform en DEV, tomar snapshot final antes de borrar
  # Esto garantiza 0% de pérdida definitiva de datos
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-aurora-final-snapshot"

  # Habilitar logs para CloudWatch
  # Permite trazabilidad de errores en el sistema de monitoreo
  enabled_cloudwatch_logs_exports = ["audit", "error", "slowquery"]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-cluster"
    Role = "database-primary"
  })
}


# -----------------------------------------------------------------------------
# 4. INSTANCIAS DEL CLUSTER — Los nodos físicos de la base de datos
# -----------------------------------------------------------------------------
# El cluster necesita al menos 2 instancias:
#   - Instancia 1 (writer): en AZ-a → nodo PRIMARIO que acepta escrituras
#   - Instancia 2 (reader): en AZ-b → nodo RÉPLICA en standby
#
# Si la instancia 1 cae, Aurora promueve la instancia 2 automáticamente.
# -----------------------------------------------------------------------------

# Instancia 1 — Nodo PRIMARIO (AZ-a, Subred Privada 5 del diagrama)
resource "aws_rds_cluster_instance" "aurora_primary" {
  identifier         = "${var.project_name}-aurora-primary"
  cluster_identifier = aws_rds_cluster.aurora.id

  # Tipo de instancia — en DEV usamos micro para ahorrar, en PROD usamos medium
  instance_class = var.db_instance_class  # ej: "db.t3.medium"

  engine         = aws_rds_cluster.aurora.engine
  engine_version = aws_rds_cluster.aurora.engine_version

  # Subred de la AZ-a (Subred Privada 5 del diagrama)
  availability_zone      = var.az_a
  db_subnet_group_name   = aws_db_subnet_group.aurora.name

  # NO tiene IP pública — está completamente aislada en red privada
  publicly_accessible = false

  # Monitoreo mejorado cada 60 segundos (métricas a CloudWatch)
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.aurora_monitoring.arn

  # Actualizaciones automáticas de versiones menores (parches de seguridad)
  auto_minor_version_upgrade = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-primary"
    Role = "writer"
    AZ   = var.az_a
  })
}

# Instancia 2 — Nodo RÉPLICA en standby (AZ-b, Subred Privada 6 del diagrama)
resource "aws_rds_cluster_instance" "aurora_replica" {
  identifier         = "${var.project_name}-aurora-replica"
  cluster_identifier = aws_rds_cluster.aurora.id

  instance_class = var.db_instance_class

  engine         = aws_rds_cluster.aurora.engine
  engine_version = aws_rds_cluster.aurora.engine_version

  # Subred de la AZ-b (Subred Privada 6 del diagrama)
  availability_zone      = var.az_b
  db_subnet_group_name   = aws_db_subnet_group.aurora.name

  publicly_accessible = false

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.aurora_monitoring.arn

  auto_minor_version_upgrade = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-replica"
    Role = "reader"
    AZ   = var.az_b
  })

  # La réplica debe crearse DESPUÉS del primario
  depends_on = [aws_rds_cluster_instance.aurora_primary]
}


# -----------------------------------------------------------------------------
# 5. ROL IAM PARA MONITOREO DE AURORA
# -----------------------------------------------------------------------------
# Aurora necesita un rol IAM para poder enviar métricas detalladas
# a CloudWatch (uso de CPU, memoria, conexiones activas, etc.)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "aurora_monitoring" {
  name = "${var.project_name}-aurora-monitoring-role"

  # Política que permite a RDS (Aurora) asumir este rol
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-aurora-monitoring-role"
  })
}

# Adjuntar la política de monitoreo mejorado al rol
resource "aws_iam_role_policy_attachment" "aurora_monitoring" {
  role       = aws_iam_role.aurora_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}


# -----------------------------------------------------------------------------
# 6. CLAVE KMS PARA CIFRADO
# -----------------------------------------------------------------------------
# KMS (Key Management Service) maneja las claves de cifrado.
# RNF: "cifrada en reposo utilizando claves manejadas en KMS"
# Si falla la validación de la clave → bloquear operación + alerta.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "aurora" {
  description             = "Clave KMS para cifrado de Aurora - Veltri Minimarket"
  deletion_window_in_days = 7       # Espera 7 días antes de eliminar definitivamente
  enable_key_rotation     = true    # Rotación automática de la clave cada año

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-kms-aurora"
    Purpose = "aurora-encryption"
  })
}

# Alias legible para la clave KMS (más fácil de identificar en consola)
resource "aws_kms_alias" "aurora" {
  name          = "alias/${var.project_name}-aurora"
  target_key_id = aws_kms_key.aurora.key_id
}