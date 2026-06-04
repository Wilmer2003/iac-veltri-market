# =============================================================================
# MÓDULO: EC2 + Auto Scaling Group — Backend con Escalado Automático
# =============================================================================
# Crea instancias EC2 que ejecutan Django en Docker.
# Se escalan automáticamente según CPU:
#   - Scale UP: CPU > 75% durante 8 minutos → agregar 1 instancia
#   - Scale DOWN: CPU < 25% durante 8 minutos → remover 1 instancia
#
# ARQUITECTURA:
#   Launch Template (Define cómo crear instancias)
#         ↓
#   Auto Scaling Group (Crea/destruye instancias según demanda)
#         ↓
#   Instancias EC2 (Ejecutan Docker + Django)
#         ↓
#   Target Group → ALB (Load Balancer distribuye tráfico)
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "backend_subnet_ids" {
  description = "IDs de subredes privadas donde corren las EC2"
  type        = list(string)
}

variable "instance_profile_name" {
  description = "Nombre del Instance Profile (desde módulo IAM)"
  type        = string
}

variable "ec2_security_group_id" {
  description = "Security Group para EC2"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia (t3.micro para DEV, t3.medium para PROD)"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID (Amazon Linux 2). Dejar vacio para usar la última"
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Tamaño del volumen raíz en GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Tipo de volumen (gp2, gp3, io1, etc.)"
  type        = string
  default     = "gp3"
}

variable "min_size" {
  description = "Mínimo número de instancias"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Máximo número de instancias"
  type        = number
  default     = 4
}

variable "desired_capacity" {
  description = "Número deseado de instancias"
  type        = number
  default     = 2
}

variable "scale_up_threshold" {
  description = "CPU % para escalar hacia arriba"
  type        = number
  default     = 75
}

variable "scale_down_threshold" {
  description = "CPU % para escalar hacia abajo"
  type        = number
  default     = 25
}

variable "health_check_type" {
  description = "Tipo de health check (EC2 o ELB)"
  type        = string
  default     = "ELB"
}

variable "health_check_grace_period" {
  description = "Segundos de espera antes de health checks (para startup)"
  type        = number
  default     = 300
}

variable "ecr_repository_url" {
  description = "URL del repositorio ECR (para imagen Docker)"
  type        = string
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. DATA SOURCE: Obtener AMI más reciente
# =============================================================================
# Si no se proporciona AMI, usar Amazon Linux 2 más reciente

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}


# =============================================================================
# 2. LAUNCH TEMPLATE (Define cómo se crean las instancias)
# =============================================================================
# El template define:
#   - AMI a usar
#   - Tipo de instancia
#   - Security Groups
#   - User data (script que corre al iniciar)
#   - IAM role (permisos)
#   - EBS volume
#   - Monitoring

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type

  # IAM Role
  iam_instance_profile {
    name = var.instance_profile_name
  }

  # Security Group
  vpc_security_group_ids = [var.ec2_security_group_id]

  # EBS Root Volume
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      delete_on_termination = true
      encrypted             = true
    }
  }

  # CloudWatch Monitoring
  monitoring {
    enabled = true
  }

  # User Data Script
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    project_name      = var.project_name
    ecr_repository    = var.ecr_repository_url
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 es más seguro
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      Name = "${var.project_name}-backend-instance"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.common_tags, {
      Name = "${var.project_name}-backend-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}


# =============================================================================
# 3. AUTO SCALING GROUP
# =============================================================================
# Administra el número de instancias según las métricas de CPU.

resource "aws_autoscaling_group" "app" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = var.backend_subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_period
  default_cooldown          = 300

  tag {
    key                 = "Name"
    value               = "${var.project_name}-asg-instance"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}


# =============================================================================
# 4. SCALING POLICIES (Scale Up / Scale Down)
# =============================================================================

# Scale UP: cuando CPU > 75% durante 8 minutos
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${var.project_name}-scale-up"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 60
}

resource "aws_cloudwatch_metric_alarm" "scale_up" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2  # 2 × 4 minutos = 8 minutos
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300  # 5 minutos
  statistic           = "Average"
  threshold           = var.scale_up_threshold
  alarm_description   = "Escalar hacia arriba si CPU > ${var.scale_up_threshold}%"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_up.arn]
}

# Scale DOWN: cuando CPU < 25% durante 8 minutos
resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${var.project_name}-scale-down"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "scale_down" {
  alarm_name          = "${var.project_name}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2  # 2 × 4 minutos = 8 minutos
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300  # 5 minutos
  statistic           = "Average"
  threshold           = var.scale_down_threshold
  alarm_description   = "Escalar hacia abajo si CPU < ${var.scale_down_threshold}%"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_down.arn]
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "asg_name" {
  description = "Nombre del Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "asg_arn" {
  description = "ARN del Auto Scaling Group"
  value       = aws_autoscaling_group.app.arn
}

output "launch_template_id" {
  description = "ID del Launch Template"
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Versión más reciente del Launch Template"
  value       = aws_launch_template.app.latest_version_number
}
