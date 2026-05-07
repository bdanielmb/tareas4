# tareas4 — Integración AWS Lambda con Terraform

## ¿Qué hace este proyecto?

Despliega una arquitectura serverless en AWS usando Terraform,
replicada en tres ambientes separados: **DEV**, **QA** y **PROD**
mediante Terraform Workspaces.

## Flujo de la arquitectura
Usuario → API Gateway → Lambda (subida) → S3 carpeta uploads/
↓
Notificación S3 → SQS
↓
Lambda (recorte) → S3 carpeta processed/
↓
DLQ → Alarma CloudWatch

## Servicios utilizados

| Servicio | Rol |
|---|---|
| API Gateway HTTP v2 | Punto de entrada HTTP para subir imágenes |
| Lambda upload | Recibe la imagen y la almacena en S3 |
| Lambda crop | Procesa la imagen activada por SQS |
| S3 | Almacenamiento de imágenes originales y procesadas |
| SQS + DLQ | Cola de procesamiento con manejo de errores |
| VPC + NAT | Red privada con salida a internet controlada |
| CloudWatch | Registro de logs y monitoreo de errores |

## Comandos para desplegar

```bash
cd terraform
terraform init

terraform workspace select dev
terraform apply -auto-approve

terraform workspace select qa
terraform apply -auto-approve

terraform workspace select prod
terraform apply -auto-approve
```

## Probar el endpoint

```bash
terraform output api_endpoint

curl -i -X POST https://TU_URL/upload \
  -H "Content-Type: image/png" \
  --data-binary "@foto.png"
```

## Eliminar recursos

```bash
terraform workspace select dev && terraform destroy -auto-approve
terraform workspace select qa && terraform destroy -auto-approve
terraform workspace select prod && terraform destroy -auto-approve
```