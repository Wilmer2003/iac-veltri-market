# =============================================================================
# MÓDULO: ECR — Elastic Container Registry (Repositorio Docker)
# =============================================================================
# ECR es el repositorio privado de Docker imágenes en AWS.
# Almacena las imágenes de la aplicación Django con:
#   - Inmutabilidad: no se pueden sobreescribir tags
#   - Scan automático de vulnerabilidades
#   - Retención de solo las últimas N imágenes (para ahorrar costos)
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "repository_name" {
  description = "Nombre del repositorio ECR"
  type        = string
  default     = "veltri-app"
}

variable "image_tag_mutability" {
  description = "Mutabilidad de tags (MUTABLE permite sobreescribir, IMMUTABLE no)"
  type        = string
  default     = "IMMUTABLE"
}

variable "scan_on_push" {
  description = "Escanear imágenes por vulnerabilidades al hacer push"
  type        = bool
  default     = true
}

variable "image_retention_count" {
  description = "Mantener solo las últimas N imágenes"
  type        = number
  default     = 10
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. REPOSITORIO ECR
# =============================================================================

resource "aws_ecr_repository" "app" {
  name                 = var.repository_name
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-ecr-repo"
  })
}


# =============================================================================
# 2. POLÍTICA DE RETENCIÓN DE IMÁGENES
# =============================================================================
# Mantener solo las últimas 10 imágenes para ahorrar almacenamiento.
# Esto evita llenar el repo de imágenes antiguas.

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantener solo las últimas N imágenes"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = var.image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}


# =============================================================================
# 3. POLÍTICA DE ACCESO AL REPOSITORIO
# =============================================================================
# Permite que EC2 e IAM roles hagan pull de las imágenes.
# Solo lectura — EC2 no puede hacer push.

resource "aws_ecr_repository_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPullFromEC2"
        Effect = "Allow"
        Principal = {
          AWS = "*"  # Restringiremos esto con IAM roles en EC2
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken"  # Necesario para autenticarse
        ]
      }
    ]
  })
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "repository_url" {
  description = "URL del repositorio ECR para hacer push de imágenes"
  value       = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  description = "ARN del repositorio (para referenciarlo en IAM)"
  value       = aws_ecr_repository.app.arn
}

output "registry_id" {
  description = "ID de la cuenta AWS (para docker commands)"
  value       = aws_ecr_repository.app.registry_id
}

output "repository_name" {
  description = "Nombre del repositorio"
  value       = aws_ecr_repository.app.name
}
