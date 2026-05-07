# ─── LOCALS ──────────────────────────────────────────────────────────────────
locals {
  env  = terraform.workspace   # dev | qa | prod
  name = "${var.project_name}-${local.env}"
}

# ─── RANDOM SUFFIX ───────────────────────────────────────────────────────────
resource "random_id" "suffix" {
  byte_length = 4
}

# ═══════════════════════════════════════════════════════════════════════════════
#  VPC
# ═══════════════════════════════════════════════════════════════════════════════
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support  = true
  enable_dns_hostnames  = true

  tags = { Name = "${local.name}-vpc" }
}

# ─── INTERNET GATEWAY ────────────────────────────────────────────────────────
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# ─── PUBLIC SUBNETS ──────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${count.index + 1}" }
}

# ─── PRIVATE SUBNETS ─────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-private-${count.index + 1}" }
}

# ─── ELASTIC IPs para NAT ────────────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${local.name}-eip-${count.index + 1}" }
}

# ─── NAT GATEWAYS ────────────────────────────────────────────────────────────
resource "aws_nat_gateway" "nat" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name}-nat-${count.index + 1}" }
  depends_on = [aws_internet_gateway.igw]
}

# ─── ROUTE TABLE — PUBLIC ────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── ROUTE TABLES — PRIVATE (una por AZ, apunta a su NAT) ───────────────────
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
  tags = { Name = "${local.name}-rt-private-${count.index + 1}" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECURITY GROUPS
# ═══════════════════════════════════════════════════════════════════════════════
resource "aws_security_group" "upload_lambda" {
  name        = "${local.name}-sg-upload-lambda"
  description = "SG para Lambda upload"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS hacia S3 y SQS endpoints"
  }

  tags = { Name = "${local.name}-sg-upload-lambda" }
}

resource "aws_security_group" "crop_lambda" {
  name        = "${local.name}-sg-crop-lambda"
  description = "SG para Lambda crop"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS hacia S3 y SQS endpoints"
  }

  tags = { Name = "${local.name}-sg-crop-lambda" }
}

resource "aws_security_group" "vpce_sqs" {
  name        = "${local.name}-sg-vpce-sqs"
  description = "SG para VPC Endpoint de SQS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.upload_lambda.id, aws_security_group.crop_lambda.id]
    description     = "Desde lambdas"
  }

  tags = { Name = "${local.name}-sg-vpce-sqs" }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  S3 BUCKET
# ═══════════════════════════════════════════════════════════════════════════════
resource "aws_s3_bucket" "images" {
  bucket        = "${local.name}-images-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    id     = "expire-uploads"
    status = "Enabled"
    filter { prefix = "uploads/" }
    expiration { days = 30 }
  }

  rule {
    id     = "expire-processed"
    status = "Enabled"
    filter { prefix = "processed/" }
    expiration { days = 90 }
  }
}

# ─── S3 notifica a SQS cuando se crea un objeto ──────────────────────────────
resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.images.id

  queue {
    queue_arn     = aws_sqs_queue.image_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }

  depends_on = [aws_sqs_queue_policy.allow_s3]
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SQS — QUEUE + DLQ
# ═══════════════════════════════════════════════════════════════════════════════
resource "aws_sqs_queue" "image_dlq" {
  name                      = "${local.name}-image-dlq"
  message_retention_seconds = 1209600  # 14 días
}

resource "aws_sqs_queue" "image_queue" {
  name                       = "${local.name}-image-queue"
  visibility_timeout_seconds = 360
  message_retention_seconds  = 86400   # 1 día
  receive_wait_time_seconds  = 20      # long polling
  
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.image_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "allow_s3" {
  queue_url = aws_sqs_queue.image_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.image_queue.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.images.arn }
      }
    }]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
#  VPC ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

# S3 Gateway Endpoint (gratuito)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject"]
      Resource  = "${aws_s3_bucket.images.arn}/*"
    }]
  })

  tags = { Name = "${local.name}-vpce-s3" }
}

# SQS Interface Endpoint
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce_sqs.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-vpce-sqs" }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  IAM ROLES
# ═══════════════════════════════════════════════════════════════════════════════
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Role — Upload Lambda
resource "aws_iam_role" "upload_lambda" {
  name               = "${local.name}-upload-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "upload_basic" {
  role       = aws_iam_role.upload_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "upload_vpc" {
  role       = aws_iam_role.upload_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "upload_s3" {
  name = "${local.name}-upload-s3-policy"
  role = aws_iam_role.upload_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.images.arn}/uploads/*"
    }]
  })
}

# Role — Crop Lambda
resource "aws_iam_role" "crop_lambda" {
  name               = "${local.name}-crop-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "crop_basic" {
  role       = aws_iam_role.crop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "crop_vpc" {
  role       = aws_iam_role.crop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "crop_permissions" {
  name = "${local.name}-crop-policy"
  role = aws_iam_role.crop_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.images.arn}/uploads/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.images.arn}/processed/*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.image_queue.arn
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LAMBDA — UPLOAD
# ═══════════════════════════════════════════════════════════════════════════════
data "archive_file" "upload_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src/upload"
  output_path = "${path.module}/src/upload.zip"
}

resource "aws_lambda_function" "upload" {
  filename         = data.archive_file.upload_zip.output_path
  function_name    = "${local.name}-upload"
  role             = aws_iam_role.upload_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  memory_size      = 256
  timeout          = 30
  source_code_hash = data.archive_file.upload_zip.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.upload_lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET     = aws_s3_bucket.images.bucket
      UPLOAD_PREFIX = "uploads/"
      ENVIRONMENT   = local.env
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LAMBDA — CROP
# ═══════════════════════════════════════════════════════════════════════════════
data "archive_file" "crop_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src/crop"
  output_path = "${path.module}/src/crop.zip"
}

resource "aws_lambda_function" "crop" {
  filename         = data.archive_file.crop_zip.output_path
  function_name    = "${local.name}-crop"
  role             = aws_iam_role.crop_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  memory_size      = 512
  timeout          = 60
  source_code_hash = data.archive_file.crop_zip.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.crop_lambda.id]
  }

  environment {
    variables = {
      S3_BUCKET        = aws_s3_bucket.images.bucket
      PROCESSED_PREFIX = "processed/"
      ENVIRONMENT      = local.env
    }
  }
}

# ─── SQS Event Source Mapping → crop Lambda ──────────────────────────────────
resource "aws_lambda_event_source_mapping" "sqs_to_crop" {
  event_source_arn                   = aws_sqs_queue.image_queue.arn
  function_name                      = aws_lambda_function.crop.arn
  batch_size                         = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

# ═══════════════════════════════════════════════════════════════════════════════
#  API GATEWAY HTTP v2
# ═══════════════════════════════════════════════════════════════════════════════
resource "aws_apigatewayv2_api" "api" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format          = "$context.requestId $context.status $context.error.message"
  }
}

resource "aws_apigatewayv2_integration" "upload" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.upload.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "upload" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /upload"
  target    = "integrations/${aws_apigatewayv2_integration.upload.id}"
}

resource "aws_lambda_permission" "apigw_upload" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.upload.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CLOUDWATCH — LOG GROUPS + ALARMA
# ═══════════════════════════════════════════════════════════════════════════════
resource "aws_cloudwatch_log_group" "upload_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.upload.function_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "crop_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.crop.function_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_metric_alarm" "dlq_alarm" {
  alarm_name          = "${local.name}-dlq-messages-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Mensajes en DLQ detectados"

  dimensions = {
    QueueName = aws_sqs_queue.image_dlq.name
  }
}