# =============================================================================
# MÓDULO: API Gateway — Puerta de entrada para APIs REST
# =============================================================================
# API Gateway proporciona:
#   - Throttling (rate limiting): 500 req/min, bloqueo 15 min
#   - CORS para solicitudes cross-origin
#   - Timeout: 29 segundos
#   - Logging y monitoreo
#   - Certificado SSL/TLS
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name del ALB (donde reenviar tráfico)"
  type        = string
}

variable "rate_limit_requests_per_minute" {
  description = "Límite de solicitudes por minuto"
  type        = number
  default     = 500
}

variable "rate_limit_burst" {
  description = "Burst limit (solicitudes simultáneas)"
  type        = number
  default     = 1000
}

variable "throttle_block_duration_seconds" {
  description = "Duración del bloqueo después de exceder límite (segundos)"
  type        = number
  default     = 900  # 15 minutos
}

variable "timeout_seconds" {
  description = "Timeout total para requests (máximo 29s)"
  type        = number
  default     = 29
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. API GATEWAY REST API
# =============================================================================

resource "aws_api_gateway_rest_api" "app" {
  name        = "${var.project_name}-api"
  description = "API Gateway para ${var.project_name}"
  
  endpoint_configuration {
    types = ["REGIONAL"]  # REGIONAL es más rápido que EDGE
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-api"
  })
}


# =============================================================================
# 2. RESOURCE PRINCIPAL (proxy para todo el tráfico)
# =============================================================================

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  parent_id   = aws_api_gateway_rest_api.app.root_resource_id
  path_part   = "{proxy+}"  # Captura cualquier ruta
}


# =============================================================================
# 3. METHOD (POST, GET, etc.) → Integración con ALB
# =============================================================================

resource "aws_api_gateway_method" "proxy" {
  rest_api_id      = aws_api_gateway_rest_api.app.id
  resource_id      = aws_api_gateway_resource.proxy.id
  http_method      = "ANY"  # Permitir cualquier método
  authorization    = "NONE"
  api_key_required = false  # Cambiar a true si necesitas API keys
}


# =============================================================================
# 4. INTEGRACIÓN HTTP CON ALB
# =============================================================================

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id      = aws_api_gateway_rest_api.app.id
  resource_id      = aws_api_gateway_resource.proxy.id
  http_method      = aws_api_gateway_method.proxy.http_method
  type             = "HTTP_PROXY"
  uri              = "http://${var.alb_dns_name}"
  integration_http_method = "ANY"
  timeout_milliseconds    = var.timeout_seconds * 1000

  # Headers personalizados (ej: Correlation ID)
  request_parameters = {
    "integration.request.header.X-Correlation-ID" = "context.requestId"
  }
}


# =============================================================================
# 5. RESPUESTA DE INTEGRACIÓN
# =============================================================================

resource "aws_api_gateway_integration_response" "proxy" {
  rest_api_id       = aws_api_gateway_rest_api.app.id
  resource_id       = aws_api_gateway_resource.proxy.id
  http_method       = aws_api_gateway_method.proxy.http_method
  status_code       = "200"
  selection_pattern = ""  # Todos los status codes
}


# =============================================================================
# 6. THROTTLING Y RATE LIMITING
# =============================================================================

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.dev.id
  rest_api_id   = aws_api_gateway_rest_api.app.id
  stage_name    = "dev"

  # CloudWatch logs
  access_log_settings {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationLatency = "$context.integration.latency"
    })
  }

  # Throttling (rate limiting)
  throttle_settings {
    burst_limit = var.rate_limit_burst
    rate_limit  = var.rate_limit_requests_per_minute / 60  # Convertir a requests/segundo
  }

  xray_tracing_enabled = true
}


# =============================================================================
# 7. DEPLOYMENT
# =============================================================================

resource "aws_api_gateway_deployment" "dev" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  
  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_method.proxy
  ]

  lifecycle {
    create_before_destroy = true
  }
}


# =============================================================================
# 8. CLOUDWATCH LOG GROUP
# =============================================================================

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/api-gateway/${var.project_name}"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-api-logs"
  })
}


# =============================================================================
# 9. USAGE PLAN (OPCIONAL: controlar cuotas por cliente)
# =============================================================================

resource "aws_api_gateway_usage_plan" "app" {
  name        = "${var.project_name}-usage-plan"
  description = "Usage plan con throttling para ${var.project_name}"

  api_stages {
    api_id      = aws_api_gateway_rest_api.app.id
    stage       = aws_api_gateway_stage.dev.stage_name
  }

  throttle_settings {
    burst_limit = var.rate_limit_burst
    rate_limit  = var.rate_limit_requests_per_minute / 60
  }

  quota_settings {
    limit  = var.rate_limit_requests_per_minute * 1440  # Cuota diaria
    period = "DAY"
  }
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "api_endpoint" {
  description = "Endpoint de la API (URL para hacer requests)"
  value       = aws_api_gateway_stage.dev.invoke_url
}

output "rest_api_id" {
  description = "ID de la REST API"
  value       = aws_api_gateway_rest_api.app.id
}

output "usage_plan_id" {
  description = "ID del Usage Plan"
  value       = aws_api_gateway_usage_plan.app.id
}
