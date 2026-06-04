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


# =============================================================================
# MÓDULO 2: Security Groups (Firewall por capas)
# =============================================================================

module "security_groups" {
  source = "../../modules/security_groups"

  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = module.vpc.vpc_cidr

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# =============================================================================
# MÓDULO 3: Secrets Manager (Gestión de credenciales)
# =============================================================================

module "secrets_manager" {
  source = "../../modules/secrets_manager"

  project_name      = var.project_name
  aurora_endpoint   = module.aurora.cluster_endpoint
  aurora_port       = 3306
  aurora_username   = "admin"
  aurora_db_name    = "veltri_prod"

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  depends_on = [module.aurora]
}


# =============================================================================
# MÓDULO 4: Aurora MySQL (Base de datos Multi-AZ)
# =============================================================================

module "aurora" {
  source = "../../modules/aurora"

  project_name          = var.project_name
  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.private_db_subnet_ids
  db_security_group_id  = module.security_groups.sg_aurora_id
  
  instance_class        = "db.t3.micro"
  backup_retention_days = 7
  multi_az              = true
  
  master_username = "admin"
  master_password = random_password.aurora_master_password.result
  database_name   = "veltri_prod"

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  depends_on = [module.vpc, module.security_groups]
}

resource "random_password" "aurora_master_password" {
  length  = 32
  special = true
}


# =============================================================================
# MÓDULO 5: ElastiCache Redis (Caché en memoria)
# =============================================================================

module "elasticache" {
  source = "../../modules/elasticache"

  project_name              = var.project_name
  vpc_id                    = module.vpc.vpc_id
  cache_subnet_ids          = module.vpc.private_backend_subnet_ids
  cache_security_group_id   = module.security_groups.sg_elasticache_id
  
  node_type                 = "cache.t3.micro"
  num_cache_nodes           = 3
  automatic_failover        = true
  multi_az                  = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  depends_on = [module.vpc, module.security_groups]
}


# =============================================================================
# MÓDULO 6: IAM Roles (Permisos para EC2 y Lambda)
# =============================================================================

module "iam" {
  source = "../../modules/iam"

  project_name         = var.project_name
  ecr_repository_arn   = module.ecr.repository_arn
  secrets_manager_arn  = module.secrets_manager.secret_arn

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  depends_on = [module.ecr, module.secrets_manager]
}


# =============================================================================
# MÓDULO 7: ECR (Repositorio de imágenes Docker)
# =============================================================================

module "ecr" {
  source = "../../modules/ecr"

  project_name        = var.project_name
  repository_name     = "veltri-app"
  image_tag_mutability = "IMMUTABLE"
  scan_on_push        = true
  image_retention_count = 10

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}


# =============================================================================
# MÓDULO 8: EC2 + Auto Scaling Group (Backend con escalado automático)
# =============================================================================

module "ec2_asg" {
  source = "../../modules/ec2_asg"

  project_name               = var.project_name
  vpc_id                     = module.vpc.vpc_id
  backend_subnet_ids         = module.vpc.private_backend_subnet_ids
  instance_profile_name      = module.iam.ec2_instance_profile_name
  ec2_security_group_id      = module.security_groups.sg_ec2_id
  
  instance_type              = "t3.micro"
  min_size                   = 2
  max_size                   = 4
  desired_capacity           = 2
  scale_up_threshold         = 75
  scale_down_threshold       = 25
  
  ecr_repository_url         = module.ecr.repository_url
  health_check_grace_period  = 300

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  depends_on = [module.iam, module.ecr, module.security_groups, module.vpc]
}


# =============================================================================
# MÓDULO 9: ALB (Application Load Balancer)
# =============================================================================

module "alb" {
  source = "../../modules/alb"

  project_name           = var.project_name
  vpc_id                 = module.vpc.vpc_id
  public_subnet_ids      = module.vpc.public_subnet_ids
  alb_security_group_id  = module.security_groups.sg_alb_id
  backend_subnet_ids     = module.vpc.private_backend_subnet_ids
  
  asg_name                      = module.ec2_asg.asg_name
  enable_http_to_https_redirect = true
  health_check_path             = "/health/"
  health_check_interval         = 30
  stickiness_enabled            = true
  stickiness_duration           = 86400

  common_tags = {
    Project     = "veltri-minimarket"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  depends_on = [module.ec2_asg, module.security_groups]
}


# =============================================================================
# OUTPUTS DEL ENTORNO DEV
# =============================================================================

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

output "aurora_endpoint" {
  description = "Endpoint de Aurora para conexiones"
  value       = module.aurora.cluster_endpoint
}

output "elasticache_endpoint" {
  description = "Endpoint de Redis"
  value       = module.elasticache.primary_endpoint_address
}

output "ecr_repository_url" {
  description = "URL del repositorio ECR"
  value       = module.ecr.repository_url
}

output "alb_dns_name" {
  description = "DNS name del Application Load Balancer"
  value       = module.alb.alb_dns_name
}
