# =============================================================================
# ENTORNO: DEV — main.tf
# =============================================================================
# Este archivo es el "orquestador" del entorno de desarrollo.
# Llama a los módulos (vpc, security_groups, etc.) con valores de DEV:
#   - Una sola AZ (para ahorrar costos en desarrollo)
#   - Instancias más pequeñas
#   - Sin Multi-AZ en Aurora
#
# Para desplegar este entorno:
#   cd terraform/environments/dev
#   terraform init
#   terraform plan
#   terraform apply
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURACIÓN DEL PROVIDER AWS
# -----------------------------------------------------------------------------
# Especifica la región y versión mínima del provider Terraform para AWS.
# La región debe coincidir con donde tienen acceso en la cuenta AWS.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"  # Versión mínima de Terraform

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"  # Usar AWS Provider v5.x
    }
  }

  # Backend remoto para guardar el tfstate en S3 (trabajo grupal)
  # Descomentar cuando tengan el bucket S3 y la tabla DynamoDB creados.
  # IMPORTANTE: El tfstate guarda el estado real de la infraestructura.
  # Si se pierde, Terraform no sabe qué recursos ya existen.
  #
  # backend "s3" {
  #   bucket         = "veltri-terraform-state-dev"   # Bucket S3 para el tfstate
  #   key            = "dev/terraform.tfstate"         # Ruta dentro del bucket
  #   region         = "us-east-1"
  #   dynamodb_table = "veltri-terraform-locks"        # Tabla para bloqueo de estado
  #   encrypt        = true                            # Cifrar el tfstate en reposo
  # }
}

provider "aws" {
  region = var.aws_region

  # Tags por defecto que se aplican a TODOS los recursos automáticamente
  default_tags {
    tags = {
      Project     = "veltri-minimarket"
      Environment = "dev"
      ManagedBy   = "terraform"
      Team        = "upao-sistemas"
    }
  }
}


# -----------------------------------------------------------------------------
# VARIABLES DEL ENTORNO DEV
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "Región AWS donde se desplegará la infraestructura."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "veltri-dev"
}


# -----------------------------------------------------------------------------
# MÓDULO 1: VPC (Red principal)
# -----------------------------------------------------------------------------
# Primer módulo en ejecutarse. Crea toda la red antes que cualquier otra cosa.
# -----------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name

  # Bloques CIDR de la red
  vpc_cidr               = "10.0.0.0/16"
  public_subnet_1_cidr   = "10.0.1.0/24"
  public_subnet_2_cidr   = "10.0.2.0/24"
  private_backend_1_cidr = "10.0.3.0/24"
  private_backend_2_cidr = "10.0.4.0/24"
  private_db_1_cidr      = "10.0.5.0/24"
  private_db_2_cidr      = "10.0.6.0/24"

  # En DEV usamos las primeras 2 AZs disponibles de us-east-1
  az_a = "us-east-1a"
  az_b = "us-east-1b"

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# -----------------------------------------------------------------------------
# MÓDULO 2: Security Groups (Firewall por capas)
# -----------------------------------------------------------------------------
# Segundo en ejecutarse. Necesita el vpc_id del módulo anterior.
# Terraform resuelve esta dependencia automáticamente.
# -----------------------------------------------------------------------------

module "security_groups" {
  source = "../../modules/security_groups"

  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id    # <-- Referencia al output del módulo vpc
  vpc_cidr     = module.vpc.vpc_cidr

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# -----------------------------------------------------------------------------
# OUTPUTS DEL ENTORNO DEV
# -----------------------------------------------------------------------------
# Muestra información útil después de aplicar Terraform.
# Verás estos valores con: terraform output
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID de la VPC creada"
  value       = module.vpc.vpc_id
}

output "nat_gateway_ips" {
  description = "IPs públicas de los NAT Gateways (para whitelist)"
  value = {
    az_a = module.vpc.nat_gateway_a_ip
    az_b = module.vpc.nat_gateway_b_ip
  }
}

output "security_group_ids" {
  description = "IDs de los Security Groups creados"
  value = {
    alb          = module.security_groups.sg_alb_id
    ec2          = module.security_groups.sg_ec2_id
    aurora       = module.security_groups.sg_aurora_id
    elasticache  = module.security_groups.sg_elasticache_id
  }
}
