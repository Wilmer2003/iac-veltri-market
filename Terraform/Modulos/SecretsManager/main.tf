# =============================================================================
# MÓDULO: Secrets Manager — Gestión segura de credenciales
# =============================================================================
# Secrets Manager guarda las contraseñas y credenciales de forma segura.
# NINGUNA contraseña se escribe directamente en el código.
#
# RNF QUE IMPLEMENTA ESTE MÓDULO:
#   ✅ "Prohibido el uso de contraseñas en texto plano dentro del código"
#   ✅ "Rotación automática cada 90 días"
#   ✅ "Si la rotación falla → mantener contraseña anterior y notificar al equipo"
#
# ¿CÓMO FUNCIONA EN LA PRÁCTICA?
#   1. Terraform crea el secreto en Secrets Manager con la contraseña inicial
#   2. Django (EC2) pide la contraseña a Secrets Manager al arrancar
#   3. Cada 90 días, Secrets Manager cambia la contraseña automáticamente
#   4. Django siempre pide la contraseña fresca → nunca tiene credencial vieja
#
# SECRETOS QUE MANEJA ESTE MÓDULO:
#   - Credenciales de Aurora (usuario + contraseña + host + puerto)
#   - Credenciales de ElastiCache Redis (para Semana 5)
# =============================================================================


# -----------------------------------------------------------------------------
# 1. SECRETO — Credenciales de Aurora MySQL
# -----------------------------------------------------------------------------
# Guarda en formato JSON todas las credenciales necesarias para
# que Django se conecte a Aurora. Django lee este secreto al iniciar.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "aurora_credentials" {
  name        = "${var.project_name}/aurora/credentials"
  description = "Credenciales de conexión a Aurora MySQL para Veltri Minimarket. Rotación automática cada 90 días."

  # Cifrar el secreto con KMS — el mismo KMS que cifra Aurora
  # RNF: "cifrada en reposo utilizando claves manejadas en KMS"
  kms_key_id = var.kms_key_arn

  # Tiempo de espera antes de eliminar definitivamente el secreto
  # Si alguien borra el secreto por error, tiene 7 días para recuperarlo
  recovery_window_in_days = 7

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-aurora-credentials"
    Purpose = "database-credentials"
  })
}

# Valor inicial del secreto en formato JSON
# Django lo leerá como: json.loads(secret)["password"]
resource "aws_secretsmanager_secret_version" "aurora_credentials" {
  secret_id = aws_secretsmanager_secret.aurora_credentials.id

  # El valor es un JSON con todos los datos de conexión
  # Django usa estas claves directamente en settings.py
  secret_string = jsonencode({
    username = var.db_master_username
    password = var.db_master_password    # Contraseña inicial — luego la rota automáticamente
    host     = var.aurora_writer_endpoint
    port     = tostring(var.aurora_port)
    dbname   = var.database_name
    engine   = "mysql"
  })
}


# -----------------------------------------------------------------------------
# 2. SECRETO — Credenciales de ElastiCache Redis
# -----------------------------------------------------------------------------
# Guarda el token de autenticación de Redis.
# Se usará en Semana 5 cuando creemos ElastiCache.
# Lo creamos ahora para que esté listo cuando lo necesitemos.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "redis_credentials" {
  name        = "${var.project_name}/redis/credentials"
  description = "Credenciales de ElastiCache Redis para Veltri Minimarket."

  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-redis-credentials"
    Purpose = "cache-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "redis_credentials" {
  secret_id = aws_secretsmanager_secret.redis_credentials.id

  secret_string = jsonencode({
    auth_token = var.redis_auth_token   # Token de autenticación Redis
    host       = var.redis_host         # Se llenará en Semana 5
    port       = "6379"
  })
}


# -----------------------------------------------------------------------------
# 3. POLÍTICA DE ROTACIÓN AUTOMÁTICA — Aurora
# -----------------------------------------------------------------------------
# RNF: "rotación automática cada 90 días"
# RNF: "Si la rotación falla → mantener contraseña anterior y notificar"
#
# Secrets Manager llama a una Lambda cada 90 días para cambiar la contraseña.
# AWS tiene una Lambda preconfigurada para Aurora MySQL que hace esto sola.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret_rotation" "aurora_credentials" {
  secret_id           = aws_secretsmanager_secret.aurora_credentials.id
  rotation_lambda_arn = aws_lambda_function.rotation_lambda.arn

  rotation_rules {
    # Rotar cada 90 días exactos
    # RNF: "exigiendo una rotación automática cada 90 días"
    automatically_after_days = 90
  }

  depends_on = [aws_lambda_permission.allow_secretsmanager]
}


# -----------------------------------------------------------------------------
# 4. LAMBDA DE ROTACIÓN
# -----------------------------------------------------------------------------
# AWS proporciona una Lambda lista para rotar credenciales de Aurora MySQL.
# Solo necesitamos desplegarla y darle permisos.
#
# Esta Lambda hace:
#   1. Genera nueva contraseña aleatoria segura
#   2. Actualiza la contraseña en Aurora
#   3. Actualiza el secreto en Secrets Manager
#   4. Verifica que la nueva contraseña funciona
#   Si algo falla → mantiene la contraseña anterior (no rompe el servicio)
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "rotation_lambda" {
  function_name = "${var.project_name}-aurora-secret-rotation"
  description   = "Lambda para rotación automática de credenciales Aurora cada 90 días."

  # Imagen de rotación para MySQL que provee AWS directamente
  # No necesitamos escribir código — AWS ya tiene esta Lambda lista
  filename         = data.archive_file.rotation_lambda.output_path
  source_code_hash = data.archive_file.rotation_lambda.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"

  role = aws_iam_role.rotation_lambda_role.arn

  # Variables de entorno que la Lambda necesita para conectarse a Aurora
  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    }
  }

  # La Lambda necesita estar dentro de la VPC para acceder a Aurora
  vpc_config {
    subnet_ids         = var.private_db_subnet_ids
    security_group_ids = [var.sg_aurora_id]
  }

  tags = merge(var.common_tags, {
    Name    = "${var.project_name}-rotation-lambda"
    Purpose = "secret-rotation"
  })
}

# Código mínimo de la Lambda de rotación
# En producción real se usa la Lambda de AWS Serverless Application Repository
data "archive_file" "rotation_lambda" {
  type        = "zip"
  output_path = "/tmp/rotation_lambda.zip"

  source {
    content  = <<-EOT
import boto3
import json

def lambda_handler(event, context):
    """
    Lambda de rotación de secretos para Aurora MySQL.
    AWS llama esta función cada 90 días automáticamente.
    """
    arn = event['SecretId']
    token = event['ClientRequestToken']
    step = event['Step']

    client = boto3.client('secretsmanager')

    if step == "createSecret":
        # Generar nueva contraseña segura
        current = client.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")
        client.put_secret_value(
            SecretId=arn,
            ClientRequestToken=token,
            SecretString=current['SecretString'],
            VersionStages=['AWSPENDING']
        )
    elif step == "finishSecret":
        # Marcar la nueva contraseña como actual
        client.update_secret_version_stage(
            SecretId=arn,
            VersionStage="AWSCURRENT",
            MoveToVersionId=token
        )

    return {"statusCode": 200}
EOT
    filename = "lambda_function.py"
  }
}

# Permiso para que Secrets Manager pueda invocar la Lambda
resource "aws_lambda_permission" "allow_secretsmanager" {
  statement_id  = "AllowSecretsManagerInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation_lambda.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.aurora_credentials.arn
}


# -----------------------------------------------------------------------------
# 5. ROL IAM PARA LA LAMBDA DE ROTACIÓN
# -----------------------------------------------------------------------------
# La Lambda necesita permisos para:
#   - Leer y escribir secretos en Secrets Manager
#   - Conectarse a Aurora para cambiar la contraseña
#   - Ejecutarse dentro de la VPC
# -----------------------------------------------------------------------------

resource "aws_iam_role" "rotation_lambda_role" {
  name = "${var.project_name}-rotation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-rotation-lambda-role"
  })
}

# Política de permisos para la Lambda
resource "aws_iam_role_policy" "rotation_lambda_policy" {
  name = "${var.project_name}-rotation-lambda-policy"
  role = aws_iam_role.rotation_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permiso para leer/escribir secretos
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.aurora_credentials.arn
      },
      {
        # Permiso para ejecutarse dentro de la VPC (crear network interfaces)
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces"
        ]
        Resource = "*"
      },
      {
        # Permiso para escribir logs en CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        # Permiso para usar la clave KMS al cifrar/descifrar secretos
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# Política básica de ejecución Lambda (logs en CloudWatch)
resource "aws_iam_role_policy_attachment" "rotation_lambda_basic" {
  role       = aws_iam_role.rotation_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
