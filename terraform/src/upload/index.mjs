import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { randomUUID } from "crypto";

const s3 = new S3Client({ region: process.env.AWS_REGION });
const BUCKET = process.env.S3_BUCKET;
const PREFIX = process.env.UPLOAD_PREFIX || "uploads/";

export const handler = async (event) => {
  console.log("Upload event:", JSON.stringify({ 
    method: event.requestContext?.http?.method,
    path: event.rawPath,
    env: process.env.ENVIRONMENT 
  }));

  try {
   
    let body = event.body;
    if (event.isBase64Encoded) {
      body = Buffer.from(body, "base64");
    } else if (typeof body === "string") {
      body = Buffer.from(body);
    }

    if (!body || body.length === 0) {
      return {
        statusCode: 400,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ error: "Body vacío. Envía una imagen." }),
      };
    }

  
    const contentType = event.headers?.["content-type"] || "image/png";
    const ext = contentType.includes("jpeg") || contentType.includes("jpg")
      ? "jpg" : contentType.includes("gif") ? "gif"
      : contentType.includes("webp") ? "webp" : "png";

    const key = `${PREFIX}${randomUUID()}.${ext}`;

    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: key,
      Body: body,
      ContentType: contentType,
    }));

    console.log(`Imagen guardada: s3://${BUCKET}/${key}`);

    return {
      statusCode: 201,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: "Imagen recibida",
        file: key,
        bucket: BUCKET,
        environment: process.env.ENVIRONMENT,
      }),
    };
  } catch (err) {
    console.error("Error en upload:", err);
    return {
      statusCode: 500,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: err.message }),
    };
  }
};