# =============================================================================
# OUTPUTS: Módulo Aurora
# =============================================================================
# Valores que este módulo expone para que otros módulos los usen.
#
# ¿QUIÉN USA ESTOS OUTPUTS?
#   - Módulo SecretsManager → necesita el endpoint para guardar la URL de conexión
#   - Módulo EC2/ASG        → necesita el endpoint para conectar Django a Aurora
#   - Entorno Dev/Prod      → muestra info útil después del terraform apply
# =============================================================================

# Endpoint de ESCRITURA — Django usa este para INSERT, UPDATE, DELETE
# Solo el nodo primario acepta escrituras
output "aurora_writer_endpoint" {
  description = "Endpoint del nodo primario de Aurora (escritura). Úsalo en Django DATABASE HOST."
  value       = aws_rds_cluster.aurora.endpoint
}

# Endpoint de LECTURA — Para consultas SELECT de solo lectura
# Aurora balancea las lecturas entre las réplicas disponibles
output "aurora_reader_endpoint" {
  description = "Endpoint de lectura de Aurora (réplicas). Para consultas SELECT."
  value       = aws_rds_cluster.aurora.reader_endpoint
}

# Puerto de conexión (siempre 3306 para Aurora MySQL)
output "aurora_port" {
  description = "Puerto de Aurora MySQL (3306)."
  value       = aws_rds_cluster.aurora.port
}

# Nombre de la base de datos
output "aurora_database_name" {
  description = "Nombre de la base de datos creada en Aurora."
  value       = aws_rds_cluster.aurora.database_name
}

# ID del cluster — útil para referencias en CloudWatch y otros servicios
output "aurora_cluster_id" {
  description = "ID del cluster de Aurora."
  value       = aws_rds_cluster.aurora.cluster_identifier
}

# ARN del cluster — necesario para políticas IAM y KMS
output "aurora_cluster_arn" {
  description = "ARN del cluster de Aurora."
  value       = aws_rds_cluster.aurora.arn
}

# ARN de la clave KMS — Secrets Manager la necesita para cifrar las credenciales
output "kms_key_arn" {
  description = "ARN de la clave KMS usada para cifrar Aurora."
  value       = aws_kms_key.aurora.arn
}

output "kms_key_id" {
  description = "ID de la clave KMS."
  value       = aws_kms_key.aurora.key_id
}
