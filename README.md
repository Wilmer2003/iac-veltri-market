# 🛒 Veltri Minimarket — Infraestructura AWS

> Migración del sistema de escritorio a la nube AWS para la cadena de 820 minimarkets en todo el Perú.
> Proyecto del curso **Infraestructura como Código** — UPAO 2026.

---

## 👥 Equipo

| Nombre | Rol en el proyecto |
|---|---|
| Araujo Aguilar, Fabiano | |
| Velasquez Gongora, Bruno | |
| Trigozo Zarate, Tiago | |
| Ruiz Ulloa, Josué | |
| Silva Lopez, Wilmer | |

**Docente:** Ing. Leturia Rodriguez, Walter Ivan — NRC: 5592

---

## 📐 Arquitectura General

```
Internet
   │
   ▼
Route 53 (DNS < 100ms)
   │
   ▼
CloudFront (CDN) ◄── AWS WAF (filtro SQL injection, rate limit 500 req/min)
   │                     │
   ├──── S3 (archivos estáticos: imágenes, PDFs)
   │
   ▼
API Gateway (HTTPS, timeout 29s, Correlation ID)
   │
   ▼
Application Load Balancer (health check cada 30s)
   │
   ├──── Zona AZ-a ──── [Subred Privada 3] ── Auto Scaling EC2-a (Django)
   │                           │                      ▲
   │                           │                      │
   └──── Zona AZ-b ──── [Subred Privada 4] ── Auto Scaling EC2-b (Django)
                               │                      │
                               ├──────────────────────┘
                               │
                        ElastiCache Redis (< 50ms, LRU)
                               │
                    ┌──────────┴──────────┐
                    ▼                     ▼
             Aurora Primario      Aurora Réplica
           [Subred Privada 5]   [Subred Privada 6]
                 (AZ-a)               (AZ-b)
              ◄─────── Replicación síncrona ────────►
                               │
                    ┌──────────┴──────────┐
                    │                     │
                   SQS ◄───────────────────┘
                    │
                    ▼
            Lambda Functions
         (Procesamiento asíncrono)
         
         • Reportes de ventas
         • Sincronización de inventario
         • Notificaciones por email
```

---

## 📂 Estructura del repositorio

```
veltri-infra/
├── terraform/
│   ├── modules/                    # Módulos reutilizables
│   │   ├── vpc/                    # ✅ Semana 1 — Red y subredes
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── security_groups/        # ✅ Semana 1 — Firewall por capas
│   │   │   └── main.tf
│   │   ├── secrets_manager/        # 🔜 Semana 2 — Gestión de credenciales
│   │   ├── aurora/                 # 🔜 Semana 2 — Base de datos Multi-AZ
│   │   ├── elasticache/            # 🔜 Semana 2/5 — Caché Redis
│   │   ├── iam/                    # 🔜 Semana 3 — Roles y políticas
│   │   ├── ecr/                    # 🔜 Semana 3 — Repositorio Docker
│   │   ├── ec2_asg/                # 🔜 Semana 3 — Backend con Auto Scaling
│   │   ├── alb/                    # 🔜 Semana 4 — Load Balancer
│   │   ├── api_gateway/            # 🔜 Semana 4 — API Gateway
│   │   ├── s3_cloudfront/          # 🔜 Semana 5 — CDN y archivos estáticos
│   │   ├── sqs_lambda/             # 🔜 Semana 5 — Colas y procesamiento asíncrono
│   │   └── cloudwatch/             # 🔜 Semana 6 — Monitoreo
│   └── environments/
│       ├── dev/                    # ✅ Entorno de desarrollo
│       │   └── main.tf
│       └── prod/                   # 🔜 Entorno de producción
│           └── main.tf
├── backend/                        # 🔜 Semana 3 — Aplicación Django
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
├── .github/
│   └── workflows/
│       └── deploy.yml              # 🔜 Semana 3 — Pipeline CI/CD
├── documentation/                  # Guías específicas
│   ├── SEMANA1.md                  # ✅ Completado
│   ├── SEMANA2.md                  # 🔜 En progreso
│   └── DEPLOYMENT.md
├── ESTADO_PROYECTO.md              # ⭐ Análisis actual (NUEVO)
└── README.md
```

---

## 🚀 Progreso del proyecto

### ✅ Semana 1 — Capa de Red (VPC + Security Groups)
**Objetivo:** Crear toda la infraestructura de red antes de cualquier otro recurso.

**Recursos creados:**
- [x] VPC principal (`10.0.0.0/16`)
- [x] Internet Gateway
- [x] Subred pública 1 — AZ-a (NAT Gateway A)
- [x] Subred pública 2 — AZ-b (NAT Gateway B)
- [x] Subred privada 3 — Backend AZ-a (EC2 Django)
- [x] Subred privada 4 — Backend AZ-b (EC2 Django)
- [x] Subred privada 5 — Aurora primario AZ-a
- [x] Subred privada 6 — Aurora réplica AZ-b
- [x] NAT Gateway A + Elastic IP
- [x] NAT Gateway B + Elastic IP
- [x] Route Tables (públicas y privadas por AZ)
- [x] Security Group ALB (acepta HTTPS desde internet)
- [x] Security Group EC2 (solo acepta del ALB)
- [x] Security Group Aurora (solo acepta de EC2, puerto 3306)
- [x] Security Group ElastiCache (solo acepta de EC2, puerto 6379)

**Archivos:**
- `terraform/modules/vpc/main.tf`
- `terraform/modules/vpc/variables.tf`
- `terraform/modules/vpc/outputs.tf`
- `terraform/modules/security_groups/main.tf`
- `terraform/environments/dev/main.tf`

---

### 🔜 Semana 2 — Capa de Datos (Aurora + Secrets Manager)
- [ ] Aurora MySQL Multi-AZ (primario + réplica)
- [ ] DB Subnet Group
- [ ] Secrets Manager (credenciales de BD)
- [ ] Rotación automática de secretos cada 90 días
- [ ] Snapshots automáticos (retención 7 días)
- [ ] Protección contra eliminación

### 🔜 Semana 3 — Backend (EC2 + Docker + CI/CD)
- [ ] ECR con imágenes inmutables
- [ ] Dockerfile para Django
- [ ] Launch Template para EC2
- [ ] Auto Scaling Group (escala al 75% CPU por 8 minutos)
- [ ] IAM Role para EC2 (principio de mínimo privilegio)
- [ ] Pipeline GitHub Actions (build → push ECR → deploy)

### 🔜 Semana 4 — Entrada (ALB + API Gateway)
- [ ] Application Load Balancer
- [ ] Target Groups con health checks cada 30s
- [ ] Certificado SSL/TLS (ACM)
- [ ] API Gateway con throttling (500 req/min, bloqueo 15 min)
- [ ] Timeout de 29 segundos
- [ ] Correlation ID en headers

### 🔜 Semana 5 — Rendimiento (ElastiCache + CloudFront + S3 + SQS + Lambda)
- [ ] ElastiCache Redis (política LRU, eviction al 95% memoria)
- [ ] Bucket S3 con versionado habilitado
- [ ] CloudFront distribution
- [ ] WAF con reglas SQL injection
- [ ] Cache-Control headers (24 horas)
- [ ] **SQS Queue** para procesamiento asíncrono
  - Message retention: 4 días
  - Visibility timeout: 60s
  - Dead Letter Queue habilitada
- [ ] **Lambda Functions** para procesar mensajes
  - Runtime: Python 3.11
  - Triggers: SQS, CloudWatch Events
  - Casos de uso:
    - Reportes de ventas
    - Sincronización de inventario
    - Notificaciones por email
    - Procesamiento de imágenes
  - Permisos: SQS, Aurora, Secrets Manager, CloudWatch Logs

### 🔜 Semana 6 — Monitoreo + Producción
- [ ] CloudWatch dashboards
- [ ] Alarmas (CPU > 75%, errores 5xx, latencia)
- [ ] Route 53 con failover
- [ ] Entorno PROD
- [ ] Pruebas de carga

---

## ⚙️ Cómo ejecutar el proyecto

### Pre-requisitos
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6.0
- [AWS CLI](https://aws.amazon.com/cli/) configurado con `aws configure`
- Cuenta AWS con permisos de administrador (para el curso)

### Configurar credenciales AWS
```bash
aws configure
# AWS Access Key ID: TU_ACCESS_KEY
# AWS Secret Access Key: TU_SECRET_KEY
# Default region name: us-east-1
# Default output format: json
```

### Desplegar entorno DEV (Semana 1)
```bash
# 1. Clonar el repositorio
git clone https://github.com/TU_USUARIO/veltri-infra.git
cd veltri-infra

# 2. Ir al entorno de desarrollo
cd terraform/environments/dev

# 3. Inicializar Terraform (descarga providers)
terraform init

# 4. Ver qué va a crear sin crear nada todavía
terraform plan

# 5. Crear la infraestructura
terraform apply

# 6. Ver los outputs (IPs, IDs, etc.)
terraform output

# 7. Para destruir todo (solo en DEV, nunca en PROD)
terraform destroy
```

---

## 💰 Costos estimados

| Servicio | Entorno DEV | Entorno PROD |
|---|---|---|
| EC2 t3.micro × 2 | ~$15/mes | ~$60/mes (t3.medium) |
| Aurora db.t3.micro | ~$30/mes | ~$130/mes (Multi-AZ) |
| NAT Gateway × 2 | ~$65/mes | ~$65/mes |
| API Gateway | ~$3/mes | ~$35/mes |
| CloudFront | ~$5/mes | ~$25/mes |
| S3, Route 53, WAF | ~$10/mes | ~$25/mes |
| ElastiCache t3.micro | ~$12/mes | ~$25/mes |
| **SQS** | ~$1/mes | ~$5/mes |
| **Lambda** | ~$1/mes | ~$10/mes |
| CloudWatch | ~$5/mes | ~$15/mes |
| **Total** | **~$147/mes** | **~$395/mes** |

> 💡 Para DEV pueden apagar las EC2 y Aurora fuera del horario de trabajo para reducir costos.
> 💡 SQS y Lambda tienen tier gratuito: 1M solicitudes/mes y 1M invocaciones.

---

## 📋 SLAs definidos

| Métrica | Compromiso |
|---|---|
| Disponibilidad mensual | 99.9% (máx. 44 min caída/mes) |
| Tiempo de respuesta | < 2 segundos bajo carga alta |
| Latencia CDN | < 200 ms a nivel nacional |
| Latencia caché Redis | < 50 ms en el 99% de consultas |
| RTO (recuperación ante desastre) | < 30 minutos |
| RPO (pérdida máxima de datos) | < 3 minutos |
| Failover Aurora automático | < 60 segundos |
| Reemplazo instancia caída | < 3 minutos |

---

## 🔐 Seguridad

- Todas las instancias EC2 y Aurora están en **subredes privadas** sin IP pública
- Las credenciales se gestionan con **AWS Secrets Manager** (rotación cada 90 días)
- El tráfico pasa por **AWS WAF** antes de llegar al backend
- Principio de **mínimo privilegio** en todos los roles IAM
- Todo el tráfico usa **HTTPS** (TLS 1.2+)
- Los datos en reposo están **cifrados con KMS**

---

## 📚 Referencias

- [AWS Well-Architected Framework](https://docs.aws.amazon.com/es_es/wellarchitected/latest/framework/welcome.html)
- [Documentación EC2](https://docs.aws.amazon.com/ec2/)
- [Documentación Aurora](https://docs.aws.amazon.com/rds/)
- [Documentación S3](https://docs.aws.amazon.com/s3/)
- [Documentación Terraform AWS Provider](https://developer.hashicorp.com/terraform/docs)
- [Documentación CloudFront](https://docs.aws.amazon.com/cloudfront/)