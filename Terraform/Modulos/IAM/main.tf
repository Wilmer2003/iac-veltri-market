# =============================================================================
# MÓDULO: IAM — Identity and Access Management para Roles
# =============================================================================
# Define los permisos mínimos (principio de mínimo privilegio) para:
#   - EC2: pull de ECR, acceso a Secrets Manager, CloudWatch logs
#   - Lambda: SQS, Aurora, Secrets Manager, CloudWatch logs
#   - (Otros servicios según necesidad)
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN del repositorio ECR (para permitir pull)"
  type        = string
  default     = "*"  # Si no se proporciona, permitir todos los ECRs
}

variable "secrets_manager_arn" {
  description = "ARN del secreto de Secrets Manager"
  type        = string
  default     = "*"  # Si no se proporciona, permitir lectura de todos
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. IAM ROLE PARA EC2
# =============================================================================
# Las instancias EC2 necesitan:
#   - Pull de ECR (descargar imágenes Docker)
#   - Lectura de Secrets Manager (credenciales BD)
#   - Envío de logs a CloudWatch
#   - Acceso a SSM Parameter Store (opcional)

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-ec2-role"
  })
}

# Política: acceso a ECR (pull de imágenes)
resource "aws_iam_role_policy" "ec2_ecr_policy" {
  name = "${var.project_name}-ec2-ecr-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories"
        ]
        Resource = var.ecr_repository_arn != "*" ? [var.ecr_repository_arn] : ["*"]
      }
    ]
  })
}

# Política: acceso a Secrets Manager (leer credenciales BD)
resource "aws_iam_role_policy" "ec2_secrets_policy" {
  name = "${var.project_name}-ec2-secrets-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = var.secrets_manager_arn != "*" ? [var.secrets_manager_arn] : ["arn:aws:secretsmanager:*:*:secret:${var.project_name}-*"]
      }
    ]
  })
}

# Política: envío de logs a CloudWatch
resource "aws_iam_role_policy" "ec2_cloudwatch_logs_policy" {
  name = "${var.project_name}-ec2-cloudwatch-logs-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Política: SSM Agent (opcional, para acceso remoto sin SSH)
resource "aws_iam_role_policy" "ec2_ssm_policy" {
  name = "${var.project_name}-ec2-ssm-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSSMAgent"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSSMGetParameters"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation"
        ]
        Resource = "*"
      }
    ]
  })
}

# Política: CloudWatch Metrics (enviar métricas personalizadas)
resource "aws_iam_role_policy" "ec2_cloudwatch_metrics_policy" {
  name = "${var.project_name}-ec2-cloudwatch-metrics-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance Profile (necesario para asignar el role a EC2)
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}


# =============================================================================
# 2. IAM ROLE PARA LAMBDA (Para SQS + Procesamiento asíncrono)
# =============================================================================
# Lambda necesita:
#   - Lectura de SQS (recibir y procesar mensajes)
#   - Acceso a Aurora (ejecutar queries)
#   - Acceso a Secrets Manager (credenciales)
#   - CloudWatch logs

resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-lambda-role"
  })
}

# Política: SQS (recibir mensajes, borrar después de procesar)
resource "aws_iam_role_policy" "lambda_sqs_policy" {
  name = "${var.project_name}-lambda-sqs-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSQS"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = "arn:aws:sqs:*:*:${var.project_name}-*"
      }
    ]
  })
}

# Política: Secrets Manager (leer credenciales)
resource "aws_iam_role_policy" "lambda_secrets_policy" {
  name = "${var.project_name}-lambda-secrets-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.project_name}-*"
      }
    ]
  })
}

# Política: CloudWatch Logs
resource "aws_iam_role_policy" "lambda_logs_policy" {
  name = "${var.project_name}-lambda-logs-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Política: VPC (si Lambda necesita acceder a RDS en VPC)
resource "aws_iam_role_policy" "lambda_vpc_policy" {
  name = "${var.project_name}-lambda-vpc-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowVPCExecution"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "ec2_role_arn" {
  description = "ARN del IAM role para EC2"
  value       = aws_iam_role.ec2_role.arn
}

output "ec2_role_name" {
  description = "Nombre del IAM role para EC2"
  value       = aws_iam_role.ec2_role.name
}

output "ec2_instance_profile_name" {
  description = "Nombre del Instance Profile (para asignar a Launch Template)"
  value       = aws_iam_instance_profile.ec2_profile.name
}

output "lambda_role_arn" {
  description = "ARN del IAM role para Lambda"
  value       = aws_iam_role.lambda_role.arn
}

output "lambda_role_name" {
  description = "Nombre del IAM role para Lambda"
  value       = aws_iam_role.lambda_role.name
}
