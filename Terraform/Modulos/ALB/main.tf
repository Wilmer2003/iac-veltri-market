# =============================================================================
# MÓDULO: ALB — Application Load Balancer
# =============================================================================
# El ALB distribuye el tráfico HTTPS entre las instancias EC2.
# Características:
#   - Health checks cada 30 segundos
#   - Sticky sessions (afinidad de sesión)
#   - SSL/TLS termination (desencriptado en ALB)
#   - Target groups (grupos de instancias)
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs de subredes públicas para ALB"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security Group del ALB"
  type        = string
}

variable "backend_subnet_ids" {
  description = "IDs de subredes privadas del backend (para target group)"
  type        = list(string)
}

variable "asg_name" {
  description = "Nombre del Auto Scaling Group (para asociar con target group)"
  type        = string
}

variable "enable_http_to_https_redirect" {
  description = "Redirigir HTTP (80) a HTTPS (443)"
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = "Ruta para health checks (ej: /health/)"
  type        = string
  default     = "/health/"
}

variable "health_check_interval" {
  description = "Segundos entre health checks"
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "Segundos para timeout de health check"
  type        = number
  default     = 5
}

variable "healthy_threshold" {
  description = "Checks exitosos consecutivos para marcar como healthy"
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "Checks fallidos consecutivos para marcar como unhealthy"
  type        = number
  default     = 2
}

variable "stickiness_enabled" {
  description = "Habilitar sticky sessions"
  type        = bool
  default     = true
}

variable "stickiness_duration" {
  description = "Duración de sticky sessions en segundos"
  type        = number
  default     = 86400  # 24 horas
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. APPLICATION LOAD BALANCER
# =============================================================================
# ALB de capa 7 (aplicación) que entiende HTTP/HTTPS

resource "aws_lb" "app" {
  name               = "${var.project_name}-alb"
  internal           = false  # Público (accesible desde internet)
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
  enable_http2              = true
  enable_cross_zone_load_balancing = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-alb"
  })
}


# =============================================================================
# 2. TARGET GROUP
# =============================================================================
# Grupo de instancias EC2 que recibirán el tráfico

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = 8000  # Django corre en puerto 8000 (Gunicorn)
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = var.health_check_path
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
    matcher             = "200-299"  # Aceptar códigos 2xx
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = var.stickiness_enabled
    cookie_duration = var.stickiness_duration
  }

  # Deregistration delay (tiempo para draining connections)
  deregistration_delay = 30

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-group"
  })

  depends_on = [aws_lb.app]
}


# =============================================================================
# 3. ATTACHMENT: ASOCIAR ASG CON TARGET GROUP
# =============================================================================
# Automáticamente, todas las nuevas instancias del ASG se registrarán en el target group

resource "aws_autoscaling_attachment" "app" {
  autoscaling_group_name = var.asg_name
  lb_target_group_arn    = aws_lb_target_group.app.arn
}


# =============================================================================
# 4. LISTENER HTTP (80)
# =============================================================================
# Si enable_http_to_https_redirect = true, redirige a HTTPS
# Si no, simplemente cierra las conexiones

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.enable_http_to_https_redirect ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.enable_http_to_https_redirect ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"  # Redirect permanente
      }
    }

    dynamic "forward" {
      for_each = !var.enable_http_to_https_redirect ? [1] : []
      content {
        target_group_arn = aws_lb_target_group.app.arn
      }
    }
  }
}


# =============================================================================
# 5. LISTENER HTTPS (443)
# =============================================================================
# NOTA: Necesita un certificado SSL/TLS en AWS Certificate Manager (ACM)
#
# Pasos para crear certificado:
#   1. Ir a AWS Console → Certificate Manager
#   2. Request certificate → Solicitar dominio veltri.pe
#   3. Validar por DNS (agregar record CNAME)
#   4. Copiar el ARN del certificado
#   5. Reemplazar en variable certificate_arn

resource "aws_lb_listener" "https" {
  count             = 1  # Comentar si no tiene certificado aún
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"

  # TODO: Reemplazar con ARN del certificado real
  ssl_policy      = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn = "arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/YOUR-CERT-ID"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}


# =============================================================================
# 6. LISTENER RULE (OPCIONAL: enrutamiento avanzado)
# =============================================================================
# Permite enrutar tráfico a diferentes targets según:
#   - Path (ej: /api/* vs /admin/*)
#   - Host (ej: api.veltri.pe vs admin.veltri.pe)
#   - Headers, Query strings, etc.

# Ejemplo: enrutar /api a un backend específico
# resource "aws_lb_listener_rule" "api" {
#   listener_arn = aws_lb_listener.https[0].arn
#   priority     = 100
# 
#   action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.api.arn
#   }
# 
#   condition {
#     path_pattern {
#       values = ["/api/*"]
#     }
#   }
# }


# =============================================================================
# OUTPUTS
# =============================================================================

output "alb_dns_name" {
  description = "DNS name del ALB (para CNAME en Route 53)"
  value       = aws_lb.app.dns_name
}

output "alb_arn" {
  description = "ARN del ALB"
  value       = aws_lb.app.arn
}

output "alb_zone_id" {
  description = "Zone ID del ALB (para Route 53 alias)"
  value       = aws_lb.app.zone_id
}

output "target_group_arn" {
  description = "ARN del Target Group"
  value       = aws_lb_target_group.app.arn
}

output "target_group_name" {
  description = "Nombre del Target Group"
  value       = aws_lb_target_group.app.name
}
