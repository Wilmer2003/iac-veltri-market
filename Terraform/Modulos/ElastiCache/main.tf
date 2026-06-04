# =============================================================================
# MÓDULO: ElastiCache Redis — Caché de Alta Velocidad
# =============================================================================
# Redis es un almacén de datos en memoria ultra-rápido (< 50ms latencia).
# Lo usamos para:
#   - Sesiones de usuario (independientes del servidor)
#   - Caché de consultas frecuentes a BD
#   - Rate limiting (cuántas solicitudes por usuario)
#   - Colas de tareas (si no usamos SQS)
#
# RNF DE RENDIMIENTO:
#   - Latencia < 50ms en 99% de consultas
#   - Política LRU (si se llena, borra los menos recientemente usados)
#   - Eviction al 95% de memoria
#   - Snapshots diarios
#   - Multi-AZ (réplicas automáticas)
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "cache_subnet_ids" {
  description = "IDs de subredes privadas para ElastiCache"
  type        = list(string)
}

variable "cache_security_group_id" {
  description = "Security Group que controla acceso a Redis"
  type        = string
}

variable "engine_version" {
  description = "Versión de Redis (6.x, 7.x, etc.)"
  type        = string
  default     = "7.0"
}

variable "node_type" {
  description = "Tipo de nodo (cache.t3.micro para DEV, cache.r6g.large para PROD)"
  type        = string
  default     = "cache.t3.micro"
}

variable "num_cache_nodes" {
  description = "Número de nodos (1 = single, 3+ = cluster mode enabled)"
  type        = number
  default     = 3
}

variable "parameter_group_family" {
  description = "Familia de parámetros (redis6.x, redis7.0, etc.)"
  type        = string
  default     = "redis7.0"
}

variable "automatic_failover" {
  description = "Failover automático (true = Multi-AZ, false = single AZ)"
  type        = bool
  default     = true
}

variable "multi_az" {
  description = "Multi-AZ enabled"
  type        = bool
  default     = true
}

variable "snapshot_retention_days" {
  description = "Días de retención de snapshots (0 = deshabilitado)"
  type        = number
  default     = 7
}

variable "at_rest_encryption_enabled" {
  description = "Cifrar datos en reposo"
  type        = bool
  default     = true
}

variable "transit_encryption_enabled" {
  description = "Cifrar datos en tránsito (TLS)"
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. CACHE SUBNET GROUP
# =============================================================================
# Define en qué subredes vive ElastiCache.
# Similar a RDS, necesita saber dónde desplegar las instancias.

resource "aws_elasticache_subnet_group" "redis" {
  name            = "${var.project_name}-redis-subnet-group"
  description     = "Subnet group para Redis ElastiCache"
  subnet_ids      = var.cache_subnet_ids

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-redis-subnet-group"
  })
}


# =============================================================================
# 2. PARAMETER GROUP (Configuración de Redis)
# =============================================================================
# Parámetros de Redis personalizados:
#   - maxmemory-policy: LRU (Least Recently Used)
#   - timeout: tiempo de inactividad antes de cerrar conexión
#   - databases: cuántas bases de datos virtuales

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${var.project_name}-redis-params"
  family      = var.parameter_group_family
  description = "Parameter group para Redis de ${var.project_name}"

  # POLÍTICA DE EVICTION: LRU (borra los menos recientemente usados)
  # Alternativas: allkeys-lfu, volatile-lru, volatile-lfu, etc.
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"  # Cuando se llene, borra los menos usados
  }

  # Timeout: cerrar conexión después de 300s sin actividad
  parameter {
    name  = "timeout"
    value = "300"
  }

  # Número de bases de datos virtuales (para separar datos por tenants)
  parameter {
    name  = "databases"
    value = "16"
  }

  # Snapshots RDB
  parameter {
    name  = "save"
    value = "900 1 300 10 60 10000"  # Guardar cada 15 min si hay 1+ cambios
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-redis-params"
  })
}


# =============================================================================
# 3. REPLICATION GROUP (El cluster Redis)
# =============================================================================
# Esto crea el "replication group" — puede ser:
#   - Single node: 1 instancia (sin HA)
#   - Cluster mode disabled: Primaria + Réplicas (pero no particionadas)
#   - Cluster mode enabled: Múltiples shards, cada shard con réplicas

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id          = "${var.project_name}-redis-cluster"
  replication_group_description = "Redis Replication Group para ${var.project_name}"
  
  engine                        = "redis"
  engine_version                = var.engine_version
  node_type                     = var.node_type
  num_cache_clusters            = var.num_cache_nodes
  parameter_group_name          = aws_elasticache_parameter_group.redis.name
  port                          = 6379  # Puerto estándar de Redis
  
  # Red
  subnet_group_name             = aws_elasticache_subnet_group.redis.name
  security_group_ids            = [var.cache_security_group_id]
  
  # High Availability
  automatic_failover_enabled    = var.automatic_failover
  multi_az_enabled              = var.multi_az
  
  # Snapshots
  snapshot_retention_limit      = var.snapshot_retention_days
  snapshot_window               = "03:00-05:00"  # 3-5 AM UTC
  
  # Mantenimiento
  maintenance_window            = "sun:05:00-sun:06:00"  # Domingos 5-6 AM
  
  # Encriptación
  at_rest_encryption_enabled    = var.at_rest_encryption_enabled
  transit_encryption_enabled    = var.transit_encryption_enabled
  auth_token_enabled            = false  # Opcional: agregar contraseña adicional
  
  # Logs
  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_logs.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
    enabled          = true
  }
  
  # Backups automáticos
  automatic_failover_enabled = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-redis-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-redis-cluster"
    Type = "cache"
  })

  depends_on = [aws_cloudwatch_log_group.redis_logs]
}


# =============================================================================
# 4. CLOUDWATCH LOG GROUP
# =============================================================================
# Logs de Redis para diagnóstico

resource "aws_cloudwatch_log_group" "redis_logs" {
  name              = "/aws/elasticache/${var.project_name}-redis"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-redis-logs"
  })
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "replication_group_id" {
  description = "ID del replication group"
  value       = aws_elasticache_replication_group.redis.id
}

output "primary_endpoint_address" {
  description = "Endpoint primario para escrituras"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Endpoint de lectura (acceso a cualquier nodo)"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "port" {
  description = "Puerto de conexión (6379)"
  value       = aws_elasticache_replication_group.redis.port
}

output "engine_version" {
  description = "Versión de Redis"
  value       = aws_elasticache_replication_group.redis.engine_version
}

output "connection_string" {
  description = "String de conexión para aplicación (formato redis://)"
  value       = "redis://${aws_elasticache_replication_group.redis.primary_endpoint_address}:${aws_elasticache_replication_group.redis.port}"
}

output "member_clusters" {
  description = "IDs de todos los nodos en el cluster"
  value       = aws_elasticache_replication_group.redis.member_clusters
}
