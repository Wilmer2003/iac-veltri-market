# =============================================================================
# OUTPUTS: Módulo SecretsManager
# =============================================================================
# Los módulos de EC2 (Semana 3) necesitan el ARN del secreto para
# que Django pueda pedirle las credenciales a Secrets Manager al arrancar.
# =============================================================================

output "aurora_secret_arn" {
  description = "ARN del secreto de Aurora. Las EC2 usan este ARN para pedir las credenciales al arrancar Django."
  value       = aws_secretsmanager_secret.aurora_credentials.arn
}

output "aurora_secret_name" {
  description = "Nombre del secreto de Aurora en Secrets Manager."
  value       = aws_secretsmanager_secret.aurora_credentials.name
}

output "redis_secret_arn" {
  description = "ARN del secreto de Redis. Se usará en Semana 5 con ElastiCache."
  value       = aws_secretsmanager_secret.redis_credentials.arn
}

output "redis_secret_name" {
  description = "Nombre del secreto de Redis."
  value       = aws_secretsmanager_secret.redis_credentials.name
}

output "rotation_lambda_arn" {
  description = "ARN de la Lambda de rotación automática."
  value       = aws_lambda_function.rotation_lambda.arn
}
