# =============================================================================
# ENTORNO: DEV — main.tf (Actualizado Semana 2)
# =============================================================================
# Este archivo conecta todos los módulos creados hasta ahora:
#   Semana 1: VPC + Security Groups
#   Semana 2: Aurora + Secrets Manager  ← NUEVO
#
# ORDEN DE EJECUCIÓN que Terraform resuelve automáticamente:
#   1. VPC (primero — todo depende de la red)
#   2. Security Groups (necesita vpc_id)
#   3. Aurora (necesita subredes privadas y sg_aurora_id)
#   4. Secrets Manager (necesita endpoint de Aurora y kms_key_arn)
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend S3 para trabajo grupal — descomentar cuando tengan el bucket
  # backend "s3" {
  #   bucket         = "veltri-terraform-state-dev"
  #   key            = "dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "veltri-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

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
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "veltri-dev"
}

# Credenciales de BD — en DEV se pasan como variables de entorno:
#   export TF_VAR_db_master_password="MiPassword123!"
# NUNCA escribir el valor aquí directamente
variable "db_master_password" {
  description = "Contraseña de Aurora. Pasar como variable de entorno: export TF_VAR_db_master_password='...' "
  type        = string
  sensitive   = true
}


# -----------------------------------------------------------------------------
# MÓDULO 1: VPC (Semana 1 — sin cambios)
# -----------------------------------------------------------------------------

module "vpc" {
  source = "../../Modulos/Vpc"

  project_name           = var.project_name
  vpc_cidr               = "10.0.0.0/16"
  public_subnet_1_cidr   = "10.0.1.0/24"
  public_subnet_2_cidr   = "10.0.2.0/24"
  private_backend_1_cidr = "10.0.3.0/24"
  private_backend_2_cidr = "10.0.4.0/24"
  private_db_1_cidr      = "10.0.5.0/24"
  private_db_2_cidr      = "10.0.6.0/24"
  az_a                   = "us-east-1a"
  az_b                   = "us-east-1b"

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# -----------------------------------------------------------------------------
# MÓDULO 2: Security Groups (Semana 1 — sin cambios)
# -----------------------------------------------------------------------------

module "security_groups" {
  source = "../../Modulos/Seguridad"

  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = module.vpc.vpc_cidr

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# -----------------------------------------------------------------------------
# MÓDULO 3: Aurora MySQL Multi-AZ (Semana 2 — NUEVO)
# -----------------------------------------------------------------------------

module "aurora" {
  source = "../../Modulos/Aurora"

  project_name = var.project_name

  # Red — viene del módulo VPC
  private_db_subnet_ids = module.vpc.private_db_subnet_ids  # Subredes 5 y 6
  sg_aurora_id          = module.security_groups.sg_aurora_id
  availability_zones    = ["us-east-1a", "us-east-1b"]
  az_a                  = "us-east-1a"
  az_b                  = "us-east-1b"

  # Base de datos
  database_name      = "veltri_db"
  db_master_username = "veltri_admin"
  db_master_password = var.db_master_password  # Viene de variable de entorno segura

  # En DEV usamos instancia pequeña para ahorrar costos (~$30/mes)
  # En PROD cambiar a "db.t3.medium" (~$130/mes)
  db_instance_class = "db.t3.micro"

  # KMS — el módulo Aurora crea su propia clave, pasamos string vacío
  kms_key_arn = ""

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# -----------------------------------------------------------------------------
# MÓDULO 4: Secrets Manager (Semana 2 — NUEVO)
# -----------------------------------------------------------------------------

module "secrets_manager" {
  source = "../../Modulos/SecretsManager"

  project_name = var.project_name
  aws_region   = var.aws_region

  # Red — para la Lambda de rotación
  private_db_subnet_ids = module.vpc.private_db_subnet_ids
  sg_aurora_id          = module.security_groups.sg_aurora_id

  # Credenciales — las mismas que Aurora
  db_master_username = "veltri_admin"
  db_master_password = var.db_master_password

  # Conexión a Aurora — viene de los outputs del módulo Aurora
  aurora_writer_endpoint = module.aurora.aurora_writer_endpoint
  aurora_port            = module.aurora.aurora_port
  database_name          = "veltri_db"

  # KMS — la misma clave que usa Aurora
  kms_key_arn = module.aurora.kms_key_arn

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# -----------------------------------------------------------------------------
# OUTPUTS DEL ENTORNO DEV
# -----------------------------------------------------------------------------

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "aurora_writer_endpoint" {
  description = "Endpoint de escritura Aurora — Django lo usará para conectarse a la BD"
  value       = module.aurora.aurora_writer_endpoint
}

output "aurora_reader_endpoint" {
  description = "Endpoint de lectura Aurora"
  value       = module.aurora.aurora_reader_endpoint
}

output "aurora_secret_arn" {
  description = "ARN del secreto de Aurora en Secrets Manager — las EC2 necesitan esto"
  value       = module.secrets_manager.aurora_secret_arn
}

output "security_group_ids" {
  value = {
    alb         = module.security_groups.sg_alb_id
    ec2         = module.security_groups.sg_ec2_id
    aurora      = module.security_groups.sg_aurora_id
    elasticache = module.security_groups.sg_elasticache_id
  }
}
