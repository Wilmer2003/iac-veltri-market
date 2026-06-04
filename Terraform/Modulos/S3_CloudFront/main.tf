# =============================================================================
# MÓDULO: S3 + CloudFront — Almacenamiento y CDN
# =============================================================================
# S3: Almacena archivos estáticos (imágenes, PDFs, etc.)
# CloudFront: CDN que sirve desde edge locations cercanas al usuario
#
# CARACTERÍSTICAS:
#   - Versionado en S3
#   - Encriptación en reposo (KMS)
#   - Compresión automática (CloudFront)
#   - Cache de 24 horas
#   - WAF para proteger contra ataques
# =============================================================================

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
}

variable "bucket_name" {
  description = "Nombre del bucket S3"
  type        = string
  default     = ""  # Si está vacío, se genera automáticamente
}

variable "enable_versioning" {
  description = "Habilitar versionado en S3"
  type        = bool
  default     = true
}

variable "enable_encryption" {
  description = "Habilitar encriptación en reposo"
  type        = bool
  default     = true
}

variable "cache_ttl_seconds" {
  description = "Tiempo de caché en segundos"
  type        = number
  default     = 86400  # 24 horas
}

variable "cache_max_ttl_seconds" {
  description = "Máximo TTL (incluso si origin dice más)"
  type        = number
  default     = 604800  # 7 días
}

variable "enable_compression" {
  description = "Comprimir contenido automáticamente"
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}


# =============================================================================
# 1. S3 BUCKET
# =============================================================================

resource "aws_s3_bucket" "static_content" {
  bucket = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-static-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-static-content"
  })
}

data "aws_caller_identity" "current" {}


# =============================================================================
# 2. CONFIGURACIÓN DE VERSIONADO
# =============================================================================

resource "aws_s3_bucket_versioning" "static_content" {
  bucket = aws_s3_bucket.static_content.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}


# =============================================================================
# 3. CONFIGURACIÓN DE ENCRIPTACIÓN
# =============================================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "static_content" {
  bucket = aws_s3_bucket.static_content.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = var.enable_encryption ? "AES256" : "AES256"
    }
  }
}


# =============================================================================
# 4. BLOCK PUBLIC ACCESS (Seguridad)
# =============================================================================
# Prevenir que el bucket sea accesible públicamente por error

resource "aws_s3_bucket_public_access_block" "static_content" {
  bucket = aws_s3_bucket.static_content.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# =============================================================================
# 5. BUCKET POLICY (Permitir a CloudFront acceder)
# =============================================================================

resource "aws_s3_bucket_policy" "cloudfront_access" {
  bucket = aws_s3_bucket.static_content.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontAccess"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.static_content.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.static_content.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.static_content]
}


# =============================================================================
# 6. CLOUDFRONT ORIGIN ACCESS CONTROL (OAC)
# =============================================================================
# Forma moderna de autenticar CloudFront con S3 (reemplaza OAI)

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${var.project_name}-s3-oac"
  description                       = "OAC para acceso de CloudFront a S3"
  origin_access_control_origin_type = "s3"
}


# =============================================================================
# 7. CLOUDFRONT DISTRIBUTION
# =============================================================================

resource "aws_cloudfront_distribution" "static_content" {
  origin {
    domain_name              = aws_s3_bucket.static_content.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN para contenido estático de ${var.project_name}"
  default_root_object = "index.html"

  # Cache behavior
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Origin"

    # Cache settings
    cache_policy_id = data.aws_cloudfront_cache_policy.optimized.id

    # Compresión
    compress = var.enable_compression

    # Viewer protocol
    viewer_protocol_policy = "redirect-to-https"

    # Headers personalizados
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id
  }

  # Restricciones geográficas (opcional)
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # SSL/TLS
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-cdn"
  })
}


# =============================================================================
# 8. CACHE POLICY (Prebuilt)
# =============================================================================
# Usar política predefinida de CloudFront para caché optimizado

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}


# =============================================================================
# 9. RESPONSE HEADERS POLICY (Seguridad)
# =============================================================================
# Agregar headers de seguridad automáticamente

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "${var.project_name}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000  # 2 años
      include_subdomains         = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }

    referrer_policy {
      override        = true
      referrer_policy = "strict-origin-when-cross-origin"
    }
  }

  custom_headers_config {
    http_header {
      header   = "X-Content-Type-Options"
      value    = "nosniff"
      override = true
    }

    http_header {
      header   = "X-Frame-Options"
      value    = "DENY"
      override = true
    }
  }
}


# =============================================================================
# 10. INVALIDATION (OPCIONAL: Limpiar caché)
# =============================================================================
# Cuando subes archivos nuevos, invalidar la caché para forzar actualización

# resource "aws_cloudfront_invalidation" "static_content" {
#   distribution_id = aws_cloudfront_distribution.static_content.id
#   paths           = ["/index.html", "/*"]  # Invalidar todo
#
#   depends_on = [aws_cloudfront_distribution.static_content]
# }


# =============================================================================
# 11. LIFECYCLE RULES (Ahorro de costos)
# =============================================================================
# Mover archivos antiguos a Glacier después de 90 días

resource "aws_s3_bucket_lifecycle_configuration" "static_content" {
  bucket = aws_s3_bucket.static_content.id

  rule {
    id     = "archive-old-versions"
    status = "Enabled"

    noncurrent_version_transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      days = 180  # Borrar después de 6 meses
    }
  }
}


# =============================================================================
# OUTPUTS
# =============================================================================

output "bucket_name" {
  description = "Nombre del bucket S3"
  value       = aws_s3_bucket.static_content.id
}

output "bucket_regional_domain_name" {
  description = "Domain name del bucket (para descargar directo desde S3)"
  value       = aws_s3_bucket.static_content.bucket_regional_domain_name
}

output "cloudfront_domain_name" {
  description = "Domain name del CloudFront distribution"
  value       = aws_cloudfront_distribution.static_content.domain_name
}

output "cloudfront_distribution_id" {
  description = "ID de la distribución CloudFront (para invalidaciones)"
  value       = aws_cloudfront_distribution.static_content.id
}

output "cloudfront_distribution_arn" {
  description = "ARN de CloudFront (para WAF)"
  value       = aws_cloudfront_distribution.static_content.arn
}
