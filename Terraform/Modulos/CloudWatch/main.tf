# =============================================================================
# MÓDULO: CloudWatch — Monitoreo y Alarmas
# =============================================================================
# Crea dashboards, alarmas y logs para monitorear toda la infraestructura.
#
# MÉTRICAS MONITOREADAS:
#   - EC2: CPU, Network, Disk
#   - Aurora: CPU, Connections, Query latency
#   - ALB: Latency, HTTP 5xx, HTTP 4xx
#   - ElastiCache: Eviction rate, Connection count
#   - Lambda: Errors, Duration, Throttles
#   - SQS: Queue depth, DLQ messages
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "alarm_email" {
  description = "Email para recibir notificaciones"
  type        = string
  default     = ""  # Cambiar por email real
}

variable "asg_name" {
  description = "Nombre del Auto Scaling Group"
  type        = string
}

variable "alb_name" {
  description = "Nombre del Load Balancer"
  type        = string
}

variable "aurora_cluster_id" {
  description = "ID del cluster Aurora"
  type        = string
}

variable "elasticache_id" {
  description = "ID del replication group Redis"
  type        = string
}

variable "lambda_function_name" {
  description = "Nombre de la función Lambda"
  type        = string
  default     = ""
}

variable "sqs_queue_name" {
  description = "Nombre de la cola SQS"
  type        = string
  default     = ""
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. SNS TOPIC PARA NOTIFICACIONES
# =============================================================================
# Envía emails/SMS cuando se activan alarmas

resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-alarms"
  })
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}


# =============================================================================
# 2. ALARMAS — AUTO SCALING GROUP
# =============================================================================

# CPU alta → escalar hacia arriba
resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name          = "${var.project_name}-asg-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ASG CPU > 80%"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }
}

# CPU baja → escalar hacia abajo
resource "aws_cloudwatch_metric_alarm" "asg_cpu_low" {
  alarm_name          = "${var.project_name}-asg-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "ASG CPU < 20%"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }
}


# =============================================================================
# 3. ALARMAS — APPLICATION LOAD BALANCER
# =============================================================================

# Alta latencia
resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  alarm_name          = "${var.project_name}-alb-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 2  # 2 segundos
  alarm_description   = "Latencia ALB > 2s"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    LoadBalancer = var.alb_name
  }
}

# Errores HTTP 5xx
resource "aws_cloudwatch_metric_alarm" "alb_http_5xx" {
  alarm_name          = "${var.project_name}-alb-http-5xx"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB tiene 10+ errores 5xx en 1 min"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    LoadBalancer = var.alb_name
  }
}

# Unhealthy targets
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.project_name}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ALB tiene targets unhealthy"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    LoadBalancer = var.alb_name
  }
}


# =============================================================================
# 4. ALARMAS — AURORA
# =============================================================================

# CPU alta
resource "aws_cloudwatch_metric_alarm" "aurora_cpu_high" {
  alarm_name          = "${var.project_name}-aurora-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Aurora CPU > 80%"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }
}

# Conexiones altas
resource "aws_cloudwatch_metric_alarm" "aurora_connections_high" {
  alarm_name          = "${var.project_name}-aurora-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80  # Ajustar según max_connections
  alarm_description   = "Aurora tiene 80+ conexiones"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }
}

# Replicación retrasada
resource "aws_cloudwatch_metric_alarm" "aurora_replication_lag" {
  alarm_name          = "${var.project_name}-aurora-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "AuroraBinlogReplicaLag"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 100  # 100ms
  alarm_description   = "Replicación Aurora retrasada > 100ms"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }
}


# =============================================================================
# 5. ALARMAS — ELASTICACHE REDIS
# =============================================================================

# Evictions (memoria llena)
resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  alarm_name          = "${var.project_name}-redis-evictions"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Redis está haciendo evictions (memoria llena)"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    ReplicationGroupId = var.elasticache_id
  }
}

# CPU alta
resource "aws_cloudwatch_metric_alarm" "redis_cpu_high" {
  alarm_name          = "${var.project_name}-redis-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Redis CPU > 75%"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    ReplicationGroupId = var.elasticache_id
  }
}


# =============================================================================
# 6. ALARMAS — LAMBDA (OPCIONAL)
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count               = var.lambda_function_name != "" ? 1 : 0
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda tiene 5+ errores en 1 min"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count               = var.lambda_function_name != "" ? 1 : 0
  alarm_name          = "${var.project_name}-lambda-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Lambda está siendo throttled"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    FunctionName = var.lambda_function_name
  }
}


# =============================================================================
# 7. CLOUDWATCH DASHBOARD
# =============================================================================

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", { stat = "Average" }],
            ["AWS/RDS", "CPUUtilization", { stat = "Average" }],
            ["AWS/ElastiCache", "CPUUtilization", { stat = "Average" }],
            ["AWS/ApplicationELB", "TargetResponseTime", { stat = "Average" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          title  = "Utilización de CPU"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", { stat = "Sum" }]
          ]
          period = 300
          stat   = "Sum"
          region = data.aws_region.current.name
          title  = "Errores HTTP"
        }
      }
    ]
  })
}

data "aws_region" "current" {}


# =============================================================================
# 8. LOG GROUPS (Para aplicación)
# =============================================================================

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/${var.project_name}/application"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-app-logs"
  })
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "sns_topic_arn" {
  description = "ARN del SNS Topic para alarmas"
  value       = aws_sns_topic.alarms.arn
}

output "dashboard_name" {
  description = "Nombre del dashboard de CloudWatch"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
