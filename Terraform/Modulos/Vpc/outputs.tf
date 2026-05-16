# =============================================================================
# OUTPUTS: Módulo VPC
# =============================================================================
# Los outputs son los valores que este módulo "expone" hacia afuera.
# Los otros módulos (EC2, Aurora, ALB, etc.) necesitan referenciar
# los IDs de las subredes y la VPC que creamos aquí.
#
# Ejemplo de uso desde otro módulo:
#   module.vpc.vpc_id
#   module.vpc.private_backend_subnet_ids
# =============================================================================

# ID de la VPC principal — necesario para crear Security Groups
output "vpc_id" {
  description = "ID único de la VPC principal de Veltri."
  value       = aws_vpc.main.id
}

# CIDR de la VPC — necesario para reglas de Security Groups que permiten
# tráfico DENTRO de la red privada
output "vpc_cidr" {
  description = "Bloque CIDR de la VPC (ej: 10.0.0.0/16)."
  value       = aws_vpc.main.cidr_block
}

# IDs de subredes públicas — el Load Balancer y NAT Gateways viven aquí
output "public_subnet_ids" {
  description = "Lista de IDs de las subredes públicas (para Load Balancer)."
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

# IDs de subredes privadas backend — el Auto Scaling Group de EC2 vive aquí
output "private_backend_subnet_ids" {
  description = "Lista de IDs de las subredes privadas del backend EC2 (Subredes 3 y 4 del diagrama)."
  value       = [aws_subnet.private_backend_1.id, aws_subnet.private_backend_2.id]
}

# IDs de subredes privadas de BD — Aurora vive aquí
output "private_db_subnet_ids" {
  description = "Lista de IDs de las subredes privadas de base de datos (Subredes 5 y 6 del diagrama)."
  value       = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id]
}

# IDs individuales (útiles para algunos recursos que requieren una sola subred)
output "public_subnet_1_id" {
  value = aws_subnet.public_1.id
}

output "public_subnet_2_id" {
  value = aws_subnet.public_2.id
}

output "private_backend_1_id" {
  value = aws_subnet.private_backend_1.id
}

output "private_backend_2_id" {
  value = aws_subnet.private_backend_2.id
}

output "private_db_1_id" {
  value = aws_subnet.private_db_1.id
}

output "private_db_2_id" {
  value = aws_subnet.private_db_2.id
}

# IPs públicas de los NAT Gateways (útiles para whitelist en servicios externos)
output "nat_gateway_a_ip" {
  description = "IP pública del NAT Gateway en AZ-a. Úsala en whitelist de servicios externos."
  value       = aws_eip.nat_a.public_ip
}

output "nat_gateway_b_ip" {
  description = "IP pública del NAT Gateway en AZ-b."
  value       = aws_eip.nat_b.public_ip
}
