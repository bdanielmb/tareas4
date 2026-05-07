output "api_endpoint" {
  description = "URL del API Gateway — usa esta para hacer POST /upload"
  value       = "${aws_apigatewayv2_api.api.api_endpoint}/upload"
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3"
  value       = aws_s3_bucket.images.bucket
}

output "sqs_queue_url" {
  description = "URL de la cola principal SQS"
  value       = aws_sqs_queue.image_queue.url
}

output "sqs_dlq_url" {
  description = "URL de la Dead-Letter Queue"
  value       = aws_sqs_queue.image_dlq.url
}

output "upload_lambda_name" {
  description = "Nombre de la Lambda upload"
  value       = aws_lambda_function.upload.function_name
}

output "crop_lambda_name" {
  description = "Nombre de la Lambda crop"
  value       = aws_lambda_function.crop.function_name
}

output "environment" {
  description = "Entorno activo"
  value       = local.env
}