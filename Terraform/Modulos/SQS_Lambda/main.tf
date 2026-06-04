# =============================================================================
# MÓDULO: SQS + Lambda — Colas de Mensajes y Procesamiento Asíncrono
# =============================================================================
# SQS es una cola de mensajes completamente administrada:
#   - Desacoplamiento entre productores y consumidores
#   - Garantía de entrega (al menos una vez)
#   - Reintentos automáticos
#   - Dead Letter Queue para mensajes que fallan
#
# Lambda procesa mensajes de la cola automáticamente.
# Casos de uso:
#   - Reportes de ventas (pueden tardar minutos)
#   - Sincronización de inventario (batch)
#   - Envío de emails/notificaciones
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC (para Lambda)"
  type        = string
}

variable "backend_subnet_ids" {
  description = "Subredes privadas donde ejecuta Lambda"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security Group para Lambda"
  type        = string
}

variable "lambda_role_arn" {
  description = "IAM Role para Lambda (desde módulo iam)"
  type        = string
}

variable "secrets_manager_arn" {
  description = "ARN del secreto de credenciales BD"
  type        = string
}

variable "message_retention_seconds" {
  description = "Segundos de retención de mensajes"
  type        = number
  default     = 345600  # 4 días
}

variable "visibility_timeout_seconds" {
  description = "Segundos de visibilidad (lambda tiene este tiempo para procesar)"
  type        = number
  default     = 60
}

variable "lambda_timeout_seconds" {
  description = "Timeout de Lambda (máx 900)"
  type        = number
  default     = 60
}

variable "lambda_memory_mb" {
  description = "Memoria de Lambda en MB (128-10240)"
  type        = number
  default     = 256
}

variable "max_receive_count" {
  description = "Reintentos antes de enviar a DLQ"
  type        = number
  default     = 3
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. SQS QUEUE (PRINCIPAL)
# =============================================================================

resource "aws_sqs_queue" "async_tasks" {
  name                        = "${var.project_name}-async-tasks"
  message_retention_seconds   = var.message_retention_seconds
  visibility_timeout_seconds  = var.visibility_timeout_seconds
  receive_wait_time_seconds   = 20  # Long polling (esperar 20s si no hay mensajes)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-async-tasks"
  })
}


# =============================================================================
# 2. SQS DEAD LETTER QUEUE (DLQ)
# =============================================================================
# Mensajes que fallan 3 veces van aquí para investigación

resource "aws_sqs_queue" "dlq" {
  name                       = "${var.project_name}-async-tasks-dlq"
  message_retention_seconds  = var.message_retention_seconds

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-async-tasks-dlq"
  })
}


# =============================================================================
# 3. SQS QUEUE POLICY (Permisos)
# =============================================================================

resource "aws_sqs_queue_policy" "async_tasks" {
  queue_url = aws_sqs_queue.async_tasks.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSendMessage"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.async_tasks.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# Obtener account ID actual
data "aws_caller_identity" "current" {}


# =============================================================================
# 4. LAMBDA FUNCTION — Procesador de mensajes
# =============================================================================

resource "aws_lambda_function" "async_processor" {
  filename      = "lambda_processor.zip"  # Ver nota abajo
  function_name = "${var.project_name}-async-processor"
  role          = var.lambda_role_arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = var.lambda_timeout_seconds
  memory_size   = var.lambda_memory_mb

  vpc_config {
    subnet_ids         = var.backend_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = {
      SECRETS_ARN = var.secrets_manager_arn
      PROJECT_NAME = var.project_name
    }
  }

  source_code_hash = filebase64sha256("lambda_processor.zip")

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-async-processor"
  })

  depends_on = [aws_iam_role_policy.lambda_vpc_policy]
}


# =============================================================================
# 5. EVENT SOURCE MAPPING (Lambda ← SQS)
# =============================================================================
# Conecta la cola SQS a Lambda automáticamente

resource "aws_lambda_event_source_mapping" "sqs_lambda" {
  event_source_arn                   = aws_sqs_queue.async_tasks.arn
  function_name                      = aws_lambda_function.async_processor.function_name
  batch_size                         = 10  # Procesar 10 mensajes a la vez
  batch_window                       = 5   # Esperar 5 segundos antes de invocar
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]  # Reintentar solo failed
}


# =============================================================================
# 6. CLOUDWATCH LOG GROUP PARA LAMBDA
# =============================================================================

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-async-processor"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-lambda-logs"
  })
}


# =============================================================================
# 7. CLOUDWATCH ALARMA (Monitorar DLQ)
# =============================================================================
# Alerta si hay mensajes en la Dead Letter Queue

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.project_name}-dlq-messages"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Hay mensajes en la DLQ que fallaron"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}


# =============================================================================
# NOTA: Lambda ZIP File
# =============================================================================
# Necesitas crear lambda_processor.zip con el código Python:
#
# Estructura esperada:
#   lambda_processor.zip
#   └── index.py
#
# Ejemplo index.py:
#   import json
#   import boto3
#   import psycopg2
#   from aws_lambda_powertools import Logger
#
#   logger = Logger()
#   secrets_client = boto3.client('secretsmanager')
#
#   def handler(event, context):
#       """
#       Procesa mensajes de SQS
#       """
#       try:
#           # Obtener credenciales de BD
#           secret = secrets_client.get_secret_value(
#               SecretId=os.environ['SECRETS_ARN']
#           )
#           db_config = json.loads(secret['SecretString'])
#
#           # Procesar cada mensaje
#           for record in event['Records']:
#               body = json.loads(record['body'])
#               logger.info(f"Procesando: {body}")
#
#               # Ejemplo: reportes
#               if body['type'] == 'report':
#                   conn = psycopg2.connect(**db_config)
#                   # ...hacer algo...
#                   conn.close()
#
#               # Marcar como procesado
#               yield {
#                   'itemId': record['messageId'],
#                   'resultCode': 'Success'
#               }
#
#       except Exception as e:
#           logger.error(str(e))
#           yield {
#               'itemId': record['messageId'],
#               'resultCode': 'Failed'
#           }
#
# Para crear el ZIP:
#   pip install aws-lambda-powertools -t package/
#   cd package && zip -r ../lambda_processor.zip . && cd ..
#   zip lambda_processor.zip index.py


# =============================================================================
# OUTPUTS
# =============================================================================

output "queue_url" {
  description = "URL de la cola SQS (para enviar mensajes)"
  value       = aws_sqs_queue.async_tasks.url
}

output "queue_arn" {
  description = "ARN de la cola (para políticas)"
  value       = aws_sqs_queue.async_tasks.arn
}

output "dlq_url" {
  description = "URL de la Dead Letter Queue"
  value       = aws_sqs_queue.dlq.url
}

output "lambda_function_name" {
  description = "Nombre de la función Lambda"
  value       = aws_lambda_function.async_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN de la función Lambda"
  value       = aws_lambda_function.async_processor.arn
}
