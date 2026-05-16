# =============================================================================
# MÓDULO: VPC - Red principal de Veltri Minimarket
# =============================================================================
# Este archivo define TODA la red de la arquitectura.
# Es el primer recurso que debe crearse porque todos los demás
# (EC2, Aurora, ElastiCache, etc.) viven dentro de esta red.
#
# Estructura que crea este módulo:
#
#   VPC (10.0.0.0/16)
#   ├── Internet Gateway          → permite que subredes públicas salgan a internet
#   ├── Subred Pública 1  (AZ-a)  → NAT Gateway A vive aquí
#   ├── Subred Pública 2  (AZ-b)  → NAT Gateway B vive aquí
#   ├── Subred Privada 3  (AZ-a)  → EC2 backend A vive aquí
#   ├── Subred Privada 4  (AZ-b)  → EC2 backend B vive aquí
#   ├── Subred Privada 5  (AZ-a)  → Aurora primario vive aquí
#   └── Subred Privada 6  (AZ-b)  → Aurora réplica vive aquí
#
# POR QUÉ 2 ZONAS DE DISPONIBILIDAD (AZ):
#   Si un datacenter de AWS falla, la otra zona sigue operando.
#   Esto garantiza el 99.9% de disponibilidad del SLA.
# =============================================================================


# -----------------------------------------------------------------------------
# 1. VPC PRINCIPAL
# -----------------------------------------------------------------------------
# La VPC (Virtual Private Cloud) es la red privada aislada donde vivirán
# todos los recursos. El bloque CIDR 10.0.0.0/16 nos da 65,536 IPs privadas
# para distribuir entre todas las subredes.
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr  # Rango IP de toda la red (ej: 10.0.0.0/16)

  # enable_dns_support y enable_dns_hostnames son OBLIGATORIOS para que
  # los servicios AWS (como Aurora) se puedan comunicar por nombre de host
  # en lugar de IP directa (más seguro y mantenible)
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}


# -----------------------------------------------------------------------------
# 2. INTERNET GATEWAY
# -----------------------------------------------------------------------------
# Puerta de entrada/salida hacia Internet para las SUBREDES PÚBLICAS.
# Las subredes PRIVADAS NO usan esto directamente — ellas salen a internet
# a través del NAT Gateway (tráfico de salida únicamente, nunca de entrada).
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-igw"
  })
}


# -----------------------------------------------------------------------------
# 3. SUBREDES PÚBLICAS (1 por cada Zona de Disponibilidad)
# -----------------------------------------------------------------------------
# ¿POR QUÉ SON "PÚBLICAS"?
#   Porque tienen una ruta directa al Internet Gateway.
#   Aquí viven los NAT Gateways — son el intermediario entre
#   las instancias privadas e internet.
#
# IMPORTANTE: Aquí NO viven EC2, ni Aurora, ni ElastiCache.
#   Solo el NAT Gateway y el Load Balancer.
# -----------------------------------------------------------------------------

# Subred Pública 1 — Zona de Disponibilidad A (eu-east-1a en el diagrama)
resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_1_cidr  # ej: 10.0.1.0/24 → 256 IPs
  availability_zone = var.az_a                   # ej: "us-east-1a"

  # map_public_ip_on_launch = false porque solo el NAT Gateway
  # necesita IP pública, no las instancias generales
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-subnet-1"
    Type = "public"
    AZ   = var.az_a
  })
}

# Subred Pública 2 — Zona de Disponibilidad B (eu-east-1b en el diagrama)
resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_2_cidr  # ej: 10.0.2.0/24
  availability_zone       = var.az_b                   # ej: "us-east-1b"
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-subnet-2"
    Type = "public"
    AZ   = var.az_b
  })
}


# -----------------------------------------------------------------------------
# 4. SUBREDES PRIVADAS PARA EL BACKEND (EC2 / Auto Scaling Group)
# -----------------------------------------------------------------------------
# ¿POR QUÉ SON "PRIVADAS"?
#   No tienen ruta al Internet Gateway.
#   Solo salen a internet a través del NAT Gateway (para descargar
#   actualizaciones, parches, imágenes Docker, etc.)
#   NADIE de internet puede iniciar una conexión hacia estas subredes.
#
# Aquí vive: EC2 con Django, dentro del Auto Scaling Group.
# -----------------------------------------------------------------------------

# Subred Privada 3 — Backend en AZ-a
resource "aws_subnet" "private_backend_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_backend_1_cidr  # ej: 10.0.3.0/24
  availability_zone = var.az_a

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-backend-subnet-1"
    Type = "private"
    Tier = "backend"
    AZ   = var.az_a
  })
}

# Subred Privada 4 — Backend en AZ-b
resource "aws_subnet" "private_backend_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_backend_2_cidr  # ej: 10.0.4.0/24
  availability_zone = var.az_b

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-backend-subnet-2"
    Type = "private"
    Tier = "backend"
    AZ   = var.az_b
  })
}


# -----------------------------------------------------------------------------
# 5. SUBREDES PRIVADAS PARA LA BASE DE DATOS (Aurora Multi-AZ)
# -----------------------------------------------------------------------------
# Separamos la BD en sus propias subredes por seguridad y buenas prácticas.
# El Requerimiento No Funcional dice que la BD debe estar en red privada
# con 0 acceso directo desde internet.
#
# Aquí viven: Aurora primario (AZ-a) y Aurora réplica (AZ-b)
# -----------------------------------------------------------------------------

# Subred Privada 5 — Aurora primario en AZ-a
resource "aws_subnet" "private_db_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_1_cidr  # ej: 10.0.5.0/24
  availability_zone = var.az_a

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-db-subnet-1"
    Type = "private"
    Tier = "database"
    AZ   = var.az_a
  })
}

# Subred Privada 6 — Aurora réplica en AZ-b
resource "aws_subnet" "private_db_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_2_cidr  # ej: 10.0.6.0/24
  availability_zone = var.az_b

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-db-subnet-2"
    Type = "private"
    Tier = "database"
    AZ   = var.az_b
  })
}


# -----------------------------------------------------------------------------
# 6. IPs ELÁSTICAS para los NAT Gateways
# -----------------------------------------------------------------------------
# Cada NAT Gateway necesita una IP pública fija (Elastic IP).
# Tenemos 2 NAT Gateways (uno por AZ) para alta disponibilidad:
# si una AZ cae, la otra AZ sigue teniendo salida a internet.
# -----------------------------------------------------------------------------

resource "aws_eip" "nat_a" {
  domain = "vpc"  # "vpc" es el valor correcto desde AWS Provider v4+

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-eip-nat-a"
  })

  # La EIP debe crearse DESPUÉS del Internet Gateway
  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "nat_b" {
  domain = "vpc"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-eip-nat-b"
  })

  depends_on = [aws_internet_gateway.main]
}


# -----------------------------------------------------------------------------
# 7. NAT GATEWAYS (uno por Zona de Disponibilidad)
# -----------------------------------------------------------------------------
# El NAT Gateway permite que las instancias en subredes PRIVADAS
# puedan SALIR a internet (para descargar Docker images, actualizaciones, etc.)
# pero NADIE de internet puede entrar a ellas.
#
# Se ubican en las subredes PÚBLICAS porque necesitan el Internet Gateway.
# Cuestan ~$32/mes cada uno → por eso en DEV puedes usar solo 1.
# -----------------------------------------------------------------------------

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id          # IP pública asignada
  subnet_id     = aws_subnet.public_1.id    # Vive en la subred PÚBLICA 1

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-gateway-a"
    AZ   = var.az_a
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_2.id    # Vive en la subred PÚBLICA 2

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-gateway-b"
    AZ   = var.az_b
  })

  depends_on = [aws_internet_gateway.main]
}


# -----------------------------------------------------------------------------
# 8. TABLAS DE ENRUTAMIENTO (Route Tables)
# -----------------------------------------------------------------------------
# Una Route Table es como el "mapa de rutas" de cada subred.
# Define a dónde va el tráfico según su destino.
#
# REGLA CLAVE:
#   - Subred pública  → tráfico 0.0.0.0/0 va al Internet Gateway
#   - Subred privada  → tráfico 0.0.0.0/0 va al NAT Gateway
# -----------------------------------------------------------------------------

# --- Route Table para subredes PÚBLICAS ---
# Todo el tráfico hacia internet (0.0.0.0/0) sale por el Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"                    # Cualquier destino externo
    gateway_id = aws_internet_gateway.main.id   # Sale por el Internet Gateway
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-rt-public"
  })
}

# Asociar subred pública 1 a la route table pública
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

# Asociar subred pública 2 a la route table pública
resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}


# --- Route Table para subredes PRIVADAS del backend — AZ-a ---
# El tráfico de salida va al NAT Gateway A (en la misma AZ para menor latencia)
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id  # Sale por NAT A
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-rt-private-a"
    AZ   = var.az_a
  })
}

resource "aws_route_table_association" "private_backend_1" {
  subnet_id      = aws_subnet.private_backend_1.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_db_1" {
  subnet_id      = aws_subnet.private_db_1.id
  route_table_id = aws_route_table.private_a.id
}


# --- Route Table para subredes PRIVADAS del backend — AZ-b ---
resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_b.id  # Sale por NAT B
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-rt-private-b"
    AZ   = var.az_b
  })
}

resource "aws_route_table_association" "private_backend_2" {
  subnet_id      = aws_subnet.private_backend_2.id
  route_table_id = aws_route_table.private_b.id
}

resource "aws_route_table_association" "private_db_2" {
  subnet_id      = aws_subnet.private_db_2.id
  route_table_id = aws_route_table.private_b.id
}