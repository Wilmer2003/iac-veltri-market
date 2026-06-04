# 📊 Estado Actual del Proyecto Veltri Minimarket

**Fecha:** Mayo 18, 2026  
**Estado General:** 33% completado  
**Próxima fase:** Semana 2 — Capa de Datos (Aurora + Secrets Manager)

---

## 🎯 Resumen Ejecutivo

| Aspecto | Estado | Progreso |
|---|---|---|
| **Capa de Red (VPC)** | ✅ Completo | 100% |
| **Firewall (Security Groups)** | ✅ Completo | 100% |
| **Capa de Datos** | ❌ No iniciado | 0% |
| **Backend (EC2 + Docker)** | ❌ No iniciado | 0% |
| **Punto de Entrada (ALB + API)** | ❌ No iniciado | 0% |
| **CDN + Cache** | ❌ No iniciado | 0% |
| **Monitoreo** | ❌ No iniciado | 0% |
| **Entorno PROD** | ❌ No iniciado | 0% |
| **Pipeline CI/CD** | ❌ No iniciado | 0% |
| **Total General** | 33% | 3 de 9 fases |

---

## ✅ Lo que YA ESTÁ IMPLEMENTADO

### Semana 1 — Infraestructura de Red

#### 1. **Módulo VPC** (`terraform/modules/vpc/`)
- **Archivo:** `main.tf` (270 líneas)
- **Recursos creados:**
  - VPC principal (`10.0.0.0/16`)
  - Internet Gateway (IGW)
  - 2 Subredes públicas (NAT Gateway)
    - `10.0.1.0/24` (AZ-a)
    - `10.0.2.0/24` (AZ-b)
  - 4 Subredes privadas
    - Backend: `10.0.3.0/24` (AZ-a), `10.0.4.0/24` (AZ-b)
    - Database: `10.0.5.0/24` (AZ-a), `10.0.6.0/24` (AZ-b)
  - 2 NAT Gateways (uno por AZ)
  - 2 Elastic IPs (para NAT)
  - Route Tables (públicas y privadas)
  - DNS habilitado (enable_dns_support, enable_dns_hostnames)

- **Logs:** Fuertemente documentado con explicaciones
- **Salidas (outputs):** VPC ID, Subnet IDs, NAT IPs, CIDR blocks
- **Estado:** ✅ Listo para producción

#### 2. **Módulo Security Groups** (`terraform/modules/security_groups/`)
- **Archivo:** `main.tf` (220 líneas)
- **Security Groups creados:**
  1. **sg-alb** → Acepta HTTPS (443) y HTTP (80) desde internet
  2. **sg-ec2** → Solo acepta puerto 8000 del ALB
  3. **sg-aurora** → Solo acepta puerto 3306 (MySQL) de EC2
  4. **sg-elasticache** → Solo acepta puerto 6379 (Redis) de EC2

- **Implementa:** Principio de mínimo privilegio
- **Estado:** ✅ Listo para producción

#### 3. **Entorno DEV** (`terraform/environments/dev/main.tf`)
- **Archivos:** 162 líneas
- **Configuración:**
  - Provider AWS con región `us-east-1`
  - Terraform backend comentado (para descomentar luego)
  - Llamadas a módulos VPC y Security Groups
  - Variables de entorno DEV
  - Outputs para verificar creación
- **Estado:** ✅ Funcional

---

## ❌ Lo que FALTA IMPLEMENTAR

### Semana 2 — Capa de Datos (Aurora + Secrets Manager)

#### 4. **Módulo Aurora** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/aurora/main.tf`

**Recursos necesarios:**
- DB Subnet Group (agrupa subredes para BD)
- Aurora MySQL Cluster
  - Instancia primaria (AZ-a)
  - Instancia réplica (AZ-b)
- Parámetros de cluster
  - Backup retention: 7 días
  - Multi-AZ habilitado
  - Encryption KMS
  - Auto-failover habilitado
- CloudWatch alarmas
- Snapshots automáticos

**Dependencias:** VPC, Security Groups

**RNF implementados:**
- ✅ 0 acceso directo desde internet
- ✅ Replicación síncrona Multi-AZ
- ✅ RTO < 30 min, RPO < 3 min
- ✅ Failover automático < 60s

---

#### 5. **Módulo Secrets Manager** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/secrets_manager/main.tf`

**Recursos necesarios:**
- Secreto de credenciales Aurora
  - Username
  - Password (aleatorio, 32 caracteres)
  - Host (endpoint de Aurora)
  - Port: 3306
  - Database: veltri_prod
- Rotación automática (cada 90 días)
- Lambda para rotación
- Permisos IAM

**Dependencias:** Aurora, IAM

---

#### 6. **Módulo ElastiCache Redis** ❌ **NO EXISTE** (Semana 5)
**Ubicación esperada:** `terraform/modules/elasticache/main.tf`

**Recursos necesarios:**
- Cache Subnet Group
- Replication Group Redis (cluster mode enabled)
- Cluster con 3 nodos (1 primario, 2 réplicas)
- Parámetros:
  - Política eviction: allkeys-lru
  - Eviction al 95% de memoria
  - Snapshots cada 24h
  - Encryption en tránsito y reposo

**Dependencias:** VPC, Security Groups

---

### Semana 3 — Backend (EC2 + Docker + CI/CD)

#### 7. **Módulo ECR** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/ecr/main.tf`

**Recursos necesarios:**
- Repositorio ECR: `veltri-app`
- Política de imagenes:
  - Inmutabilidad: habilitada
  - Scan de vulnerabilidades: habilitada
  - Retention: 10 últimas imágenes

**Dependencias:** Ninguna (pero se usa en EC2)

---

#### 8. **Módulo IAM Roles** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/iam/main.tf`

**Recursos necesarios:**
- IAM Role para EC2
  - Permisos: ECR pull, CloudWatch logs, Secrets Manager read
  - Principio de mínimo privilegio
- Instance Profile

---

#### 9. **Módulo EC2 + Auto Scaling Group** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/ec2_asg/main.tf`

**Recursos necesarios:**
- Launch Template
  - AMI: Amazon Linux 2
  - Instance type: t3.micro (DEV), t3.medium (PROD)
  - User data: instalar Docker, agent CloudWatch
  - Security Group: sg-ec2
- Auto Scaling Group
  - Min: 2, Max: 4, Desired: 2
  - Scaling policy:
    - Scale UP: CPU > 75% durante 8 minutos
    - Scale DOWN: CPU < 25% durante 8 minutos
  - Health check type: ELB
  - Health check grace period: 300s
  - Subredes privadas (3 y 4)

**Dependencias:** VPC, Security Groups, IAM, ECR

---

#### 10. **Dockerfile para Django** ❌ **NO EXISTE**
**Ubicación esperada:** `backend/Dockerfile`

**Contenido:**
- Base: `python:3.11-slim`
- Dependencias: Django, gunicorn, psycopg2, boto3
- Entrypoint: gunicorn con 4 workers

---

#### 11. **Pipeline GitHub Actions** ❌ **NO EXISTE**
**Ubicación esperada:** `.github/workflows/deploy.yml`

**Pasos:**
1. Checkout
2. Build imagen Docker
3. Push a ECR
4. Actualizar ASG (nuevo AMI/versión)

---

### Semana 4 — Punto de Entrada (ALB + API Gateway)

#### 12. **Módulo ALB** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/alb/main.tf`

**Recursos necesarios:**
- Application Load Balancer
  - Subredes públicas (1 y 2)
  - Security Group: sg-alb
  - Scheme: internet-facing
- Target Group
  - Protocolo: HTTP
  - Puerto: 8000
  - Path health check: `/health/`
  - Health check interval: 30s
  - Unhealthy threshold: 2
- Listener (HTTP 80 → 443)
- Certificado ACM (HTTPS)
- Stickiness: habilitada (duración: 86400s)

**Dependencias:** VPC, Security Groups, EC2 ASG, ACM Certificate

---

#### 13. **Módulo API Gateway** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/api_gateway/main.tf`

**Recursos necesarios:**
- REST API
  - Throttling:
    - Rate limit: 500 req/min
    - Burst limit: 1000
    - Bloqueo por 15 minutos
  - Timeout: 29 segundos
  - CORS habilitado
- Integration con ALB
- CloudWatch logging
- API Keys (opcional)

**Dependencias:** ALB

---

### Semana 5 — Rendimiento (CDN + Lambda + SQS)

#### 14. **Módulo S3 + CloudFront** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/s3_cloudfront/main.tf`

**Recursos necesarios:**
- S3 Bucket
  - Versionado: habilitado
  - Encryption: KMS
  - Block public access: habilitado
  - Lifecycle: 90 días a Glacier
- CloudFront Distribution
  - Origin: S3 bucket
  - Cache-Control: 24 horas
  - Compression: habilitada
  - Viewer protocol policy: redirect-to-https
- WAF
  - Regla: SQL injection
  - Regla: Rate limit
  - Regla: XSS

**Dependencias:** VPC (para WAF)

---

#### 15. **Módulo Lambda + SQS** ❌ **NO EXISTE** ⭐ **NUEVO EN DIAGRAMA**
**Ubicación esperada:** `terraform/modules/sqs_lambda/main.tf`

**Recursos necesarios:**
- SQS Queue
  - Nombre: `veltri-async-tasks`
  - Message retention: 4 días
  - Visibility timeout: 60s
  - Dead letter queue: habilitada
- Lambda Function
  - Runtime: Python 3.11
  - Memory: 256 MB
  - Timeout: 60s
  - Environment: DB credentials (Secrets Manager)
  - Trigger: SQS
- IAM Role para Lambda
  - Permisos: SQS receive/delete, Secrets Manager read, CloudWatch logs

**Casos de uso:**
- Procesamiento asíncrono de reportes
- Notificaciones de inventario
- Sincronización de datos

**Dependencias:** Aurora, Secrets Manager, SQS

---

### Semana 6 — Monitoreo + Producción

#### 16. **Módulo CloudWatch** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/modules/cloudwatch/main.tf`

**Recursos necesarios:**
- Dashboard principal
- Alarmas:
  - EC2 CPU > 75% (enviar email)
  - Aurora CPU > 80%
  - Errores 5xx > 10 (ALB)
  - Latencia > 2s (ALB)
  - Redis eviction > 0
  - SQS messages dlq > 0
- Log Groups:
  - ALB logs
  - EC2 logs
  - Aurora logs
  - Lambda logs

**Dependencias:** Todos los módulos

---

#### 17. **Entorno PROD** ❌ **NO EXISTE**
**Ubicación esperada:** `terraform/environments/prod/main.tf`

**Diferencias vs DEV:**
- Instancias más grandes (t3.medium vs t3.micro)
- Multi-AZ habilitado en todo
- ASG: Min 3, Max 8, Desired 3
- Backups diarios
- Replicación cross-region (opcional)
- Alertas más restrictivas

---

## 📋 Checklist de Implementación

### Semana 2 — Capa de Datos
- [ ] Crear módulo Aurora
  - [ ] DB Subnet Group
  - [ ] Cluster Aurora
  - [ ] Parámetros de cluster
  - [ ] Alarmas CloudWatch
- [ ] Crear módulo Secrets Manager
  - [ ] Secreto BD
  - [ ] Rotación automática
  - [ ] Lambda rotación
- [ ] Crear módulo ElastiCache Redis
  - [ ] Replication Group
  - [ ] Cache Subnet Group
  - [ ] Parámetros de eviction
- [ ] Actualizar `environments/dev/main.tf` con nuevos módulos
- [ ] Actualizar README.md

### Semana 3 — Backend
- [ ] Crear módulo ECR
- [ ] Crear módulo IAM Roles
- [ ] Crear módulo EC2 + ASG
- [ ] Crear `backend/Dockerfile`
- [ ] Crear `backend/requirements.txt`
- [ ] Crear `.github/workflows/deploy.yml`
- [ ] Actualizar `environments/dev/main.tf`

### Semana 4 — Entrada
- [ ] Crear módulo ALB
- [ ] Crear módulo API Gateway
- [ ] Crear certificado ACM (manual en AWS Console o Terraform)
- [ ] Actualizar `environments/dev/main.tf`

### Semana 5 — Rendimiento
- [ ] Crear módulo S3 + CloudFront + WAF
- [ ] Crear módulo Lambda + SQS ⭐ **NUEVO**
- [ ] Actualizar `environments/dev/main.tf`

### Semana 6 — Monitoreo + PROD
- [ ] Crear módulo CloudWatch
- [ ] Crear `environments/prod/main.tf`
- [ ] Validar diferencias DEV vs PROD
- [ ] Actualizar README.md

---

## 🔄 Orden de Dependencias

```
VPC ✅
│
├─→ Security Groups ✅
│   │
│   ├─→ Aurora (Secrets Manager + KMS)
│   │   │
│   │   ├─→ EC2 ASG (IAM Roles, ECR)
│   │   │   │
│   │   │   ├─→ ALB
│   │   │   │   └─→ API Gateway
│   │   │   │
│   │   │   └─→ ElastiCache
│   │   │
│   │   └─→ Lambda + SQS
│   │
│   ├─→ S3 + CloudFront + WAF
│   │
│   └─→ CloudWatch (monitoreo de todo)
│
└─→ Prod Environment (copia de dev con ajustes)
```

---

## 🚀 Próximos Pasos Inmediatos

### PRIORITARIO (Semana 2):
1. **Crear `terraform/modules/secrets_manager/main.tf`**
   - Secreto para Aurora
   - Rotación cada 90 días
   
2. **Crear `terraform/modules/aurora/main.tf`**
   - MySQL 8.0
   - Multi-AZ (2 nodos)
   - Backup 7 días
   
3. **Crear `terraform/modules/elasticache/main.tf`** (puede ser después)
   - Redis 7.0
   - 3 nodos cluster

4. **Actualizar `terraform/environments/dev/main.tf`**
   - Agregar módulos Aurora, Secrets Manager, ElastiCache

5. **Crear `documentation/SEMANA2.md`**
   - Instrucciones detalladas

---

## 📝 Cambios al README

El README debe actualizarse para:
- [ ] Agregar módulo SQS + Lambda al diagrama
- [ ] Actualizar timeline (están faltando 6 semanas de contenido)
- [ ] Agregar sección de troubleshooting
- [ ] Agregar ejemplos de despliegue
- [ ] Agregar secuencia de desarrollo

---

## 📊 Matriz de Responsabilidades

| Semana | Módulo | Complejidad | Est. Horas |
|---|---|---|---|
| 2 | Secrets Manager | Media | 2h |
| 2 | Aurora | Alta | 4h |
| 2 | ElastiCache | Media | 2h |
| 3 | ECR | Baja | 1h |
| 3 | IAM Roles | Media | 2h |
| 3 | EC2 + ASG | Alta | 4h |
| 3 | Dockerfile | Media | 2h |
| 3 | Pipeline CI/CD | Alta | 3h |
| 4 | ALB | Media | 3h |
| 4 | API Gateway | Media | 2h |
| 5 | S3 + CloudFront | Alta | 4h |
| 5 | Lambda + SQS | Media | 3h |
| 6 | CloudWatch | Media | 2h |
| 6 | Entorno PROD | Baja | 2h |
| **TOTAL** | | | **40h** |

---

## 🎯 Criterios de Aceptación

Cada módulo debe cumplir:
- [ ] Código bien documentado (comentarios explicativos)
- [ ] Variables con valores por defecto
- [ ] Outputs exportados correctamente
- [ ] Security groups configurados
- [ ] Alarmas CloudWatch
- [ ] Archivos `variables.tf` y `outputs.tf`
- [ ] Prueba local en DEV
- [ ] README específico del módulo

---

**Última actualización:** 2026-05-18  
**Próxima revisión:** 2026-05-25  
**Estado:** En Desarrollo
