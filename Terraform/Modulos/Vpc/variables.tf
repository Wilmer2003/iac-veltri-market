# =============================================================================
# VARIABLES: Módulo VPC
# =============================================================================
# Aquí se definen los parámetros que el módulo VPC recibe desde afuera.
# Esto hace el módulo REUTILIZABLE — los mismos archivos sirven para
# el entorno de DEV y PROD, solo cambian los valores de estas variables.
# =============================================================================

# -----------------------------------------------------------------------------
# Variables de identificación del proyecto
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Nombre del proyecto. Se usa como prefijo en todos los recursos para identificarlos fácilmente en la consola AWS."
  type        = string
  default     = "veltri"

  validation {
    condition     = length(var.project_name) <= 20
    error_message = "El nombre del proyecto no puede superar 20 caracteres (límite de nombres en AWS)."
  }
}

variable "common_tags" {
  description = "Tags comunes que se aplican a TODOS los recursos. Útil para filtrar costos por proyecto en AWS Cost Explorer."
  type        = map(string)
  default = {
    Project     = "veltri-minimarket"
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}


# -----------------------------------------------------------------------------
# Variables de red — Bloques CIDR
# -----------------------------------------------------------------------------
# Un bloque CIDR define un rango de IPs.
# Ejemplo: 10.0.0.0/16  = 65,536 IPs disponibles (toda la VPC)
#          10.0.1.0/24  =    256 IPs disponibles (una subred)
#
# PLANIFICACIÓN DE IPs para Veltri:
#   VPC:               10.0.0.0/16
#   Pública  AZ-a:     10.0.1.0/24
#   Pública  AZ-b:     10.0.2.0/24
#   Privada backend AZ-a: 10.0.3.0/24
#   Privada backend AZ-b: 10.0.4.0/24
#   Privada DB AZ-a:   10.0.5.0/24
#   Privada DB AZ-b:   10.0.6.0/24
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "Rango de IPs de toda la VPC. Debe ser un bloque /16 para tener suficiente espacio para todas las subredes."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_1_cidr" {
  description = "CIDR de la subred pública en AZ-a. Aquí vivirá el NAT Gateway A."
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_2_cidr" {
  description = "CIDR de la subred pública en AZ-b. Aquí vivirá el NAT Gateway B."
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_backend_1_cidr" {
  description = "CIDR de la subred privada backend en AZ-a (Subred Privada 3 del diagrama). Aquí viven las EC2 con Django."
  type        = string
  default     = "10.0.3.0/24"
}

variable "private_backend_2_cidr" {
  description = "CIDR de la subred privada backend en AZ-b (Subred Privada 4 del diagrama). Aquí viven las EC2 con Django."
  type        = string
  default     = "10.0.4.0/24"
}

variable "private_db_1_cidr" {
  description = "CIDR de la subred privada de base de datos en AZ-a (Subred Privada 5 del diagrama). Aquí vive Aurora primario."
  type        = string
  default     = "10.0.5.0/24"
}

variable "private_db_2_cidr" {
  description = "CIDR de la subred privada de base de datos en AZ-b (Subred Privada 6 del diagrama). Aquí vive Aurora réplica."
  type        = string
  default     = "10.0.6.0/24"
}


# -----------------------------------------------------------------------------
# Variables de Zonas de Disponibilidad
# -----------------------------------------------------------------------------
# Cambia estos valores según la región donde despliegues.
# Para us-east-1: usar "us-east-1a" y "us-east-1b"
# Para eu-west-1: usar "eu-west-1a" y "eu-west-1b"
# -----------------------------------------------------------------------------

variable "az_a" {
  description = "Primera Zona de Disponibilidad (AZ-a). Aquí van los recursos primarios."
  type        = string
  default     = "us-east-1a"
}

variable "az_b" {
  description = "Segunda Zona de Disponibilidad (AZ-b). Aquí van los recursos de respaldo/réplica."
  type        = string
  default     = "us-east-1b"
}
