# =============================================================================
# MÓDULO: Security Groups — Firewall por capas
# =============================================================================
# Un Security Group es como un firewall virtual que controla qué tráfico
# puede entrar (ingress) y salir (egress) de cada recurso.
#
# PRINCIPIO DE MÍNIMO PRIVILEGIO (del Requerimiento No Funcional):
#   Cada capa SOLO puede recibir tráfico de la capa que la precede.
#   Internet → ALB → EC2 → Aurora
#              ↓
#           No puede ir Internet → Aurora directamente.
#
# Security Groups que crearemos:
#   1. sg_alb          → Load Balancer (recibe HTTPS del mundo)
#   2. sg_ec2          → Instancias Django (solo recibe del ALB)
#   3. sg_aurora       → Base de datos (solo recibe de EC2)
#   4. sg_elasticache  → Redis/Memcached (solo recibe de EC2)
# =============================================================================

variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "common_tags" {
  type = map(string)
}


# -----------------------------------------------------------------------------
# 1. SECURITY GROUP — Application Load Balancer (ALB)
# -----------------------------------------------------------------------------
# El ALB es el punto de entrada al flujo dinámico.
# Debe aceptar HTTPS (443) desde cualquier IP de internet.
# NO acepta HTTP (80) — todo va por HTTPS según los RNF.
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-sg-alb"
  description = "Security Group del Application Load Balancer. Acepta HTTPS desde internet."
  vpc_id      = var.vpc_id

  # ENTRADA: Permitir HTTPS (puerto 443) desde cualquier IP
  ingress {
    description = "HTTPS desde internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Cualquier IP de internet
  }

  # ENTRADA: Puerto 80 solo para redirigir a 443 (buena práctica)
  ingress {
    description = "HTTP para redirigir a HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SALIDA: El ALB puede enviar tráfico al puerto 8000 donde corre Django
  # (Solo hacia la red interna de la VPC, no hacia internet)
  egress {
    description = "Reenvío al backend Django"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]  # Solo dentro de la VPC
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-sg-alb"
    Role = "load-balancer"
  })
}


# -----------------------------------------------------------------------------
# 2. SECURITY GROUP — Instancias EC2 (Django backend)
# -----------------------------------------------------------------------------
# Las EC2 solo deben aceptar tráfico del Load Balancer.
# NADIE más puede conectarse a ellas directamente — ni siquiera
# desde internet, ni desde otras EC2 que no sean del mismo grupo.
#
# Usamos source_security_group_id para referenciar el SG del ALB
# en lugar de un CIDR — esto es más seguro y preciso.
# -----------------------------------------------------------------------------

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-sg-ec2"
  description = "Security Group de las instancias EC2 Django. Solo acepta tráfico del ALB."
  vpc_id      = var.vpc_id

  # ENTRADA: Solo aceptar tráfico del ALB en el puerto 8000 (Gunicorn/Django)
  ingress {
    description             = "Tráfico Django desde el ALB únicamente"
    from_port               = 8000
    to_port                 = 8000
    protocol                = "tcp"
    security_groups         = [aws_security_group.alb.id]  # Solo del ALB
  }

  # SALIDA: Las EC2 necesitan salir a internet via NAT Gateway para:
  #   - Descargar imágenes Docker desde ECR
  #   - Conectarse a Aurora y ElastiCache
  #   - Descargar actualizaciones del sistema
  egress {
    description = "Salida a internet (via NAT Gateway) y hacia servicios internos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # -1 = todos los protocolos
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-sg-ec2"
    Role = "backend"
  })
}


# -----------------------------------------------------------------------------
# 3. SECURITY GROUP — Aurora MySQL
# -----------------------------------------------------------------------------
# Aurora SOLO puede recibir conexiones desde las instancias EC2.
# Puerto 3306 = MySQL (Aurora es compatible con MySQL)
#
# Esto implementa el RNF: "0 incidentes de conexiones no autorizadas"
# a la base de datos.
# -----------------------------------------------------------------------------

resource "aws_security_group" "aurora" {
  name        = "${var.project_name}-sg-aurora"
  description = "Security Group de Aurora. Solo acepta conexiones MySQL desde las EC2."
  vpc_id      = var.vpc_id

  # ENTRADA: Solo MySQL (3306) desde las instancias EC2
  ingress {
    description             = "MySQL desde las instancias EC2 backend"
    from_port               = 3306
    to_port                 = 3306
    protocol                = "tcp"
    security_groups         = [aws_security_group.ec2.id]  # Solo de EC2
  }

  # SALIDA: Aurora no necesita salida a internet — está completamente aislada
  egress {
    description = "Sin salida externa (BD completamente aislada)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]  # Solo dentro de la VPC
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-sg-aurora"
    Role = "database"
  })
}


# -----------------------------------------------------------------------------
# 4. SECURITY GROUP — ElastiCache (Redis)
# -----------------------------------------------------------------------------
# ElastiCache SOLO puede recibir conexiones desde las EC2.
# Puerto 6379 = Redis
#
# Esto implementa el RNF: caché con acceso <50ms y sesiones
# independientes del servidor.
# -----------------------------------------------------------------------------

resource "aws_security_group" "elasticache" {
  name        = "${var.project_name}-sg-elasticache"
  description = "Security Group de ElastiCache Redis. Solo acepta conexiones desde EC2."
  vpc_id      = var.vpc_id

  # ENTRADA: Solo Redis (6379) desde las instancias EC2
  ingress {
    description             = "Redis desde las instancias EC2"
    from_port               = 6379
    to_port                 = 6379
    protocol                = "tcp"
    security_groups         = [aws_security_group.ec2.id]
  }

  # SALIDA: Solo dentro de la VPC
  egress {
    description = "Sin salida externa"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-sg-elasticache"
    Role = "cache"
  })
}


# -----------------------------------------------------------------------------
# OUTPUTS: Exportar IDs de los Security Groups
# -----------------------------------------------------------------------------
# Los módulos de EC2, Aurora y ElastiCache necesitan estos IDs
# para asignarse el SG correcto.
# -----------------------------------------------------------------------------

output "sg_alb_id" {
  description = "ID del Security Group del Load Balancer"
  value       = aws_security_group.alb.id
}

output "sg_ec2_id" {
  description = "ID del Security Group de las instancias EC2"
  value       = aws_security_group.ec2.id
}

output "sg_aurora_id" {
  description = "ID del Security Group de Aurora"
  value       = aws_security_group.aurora.id
}

output "sg_elasticache_id" {
  description = "ID del Security Group de ElastiCache"
  value       = aws_security_group.elasticache.id
}
