import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";

const s3 = new S3Client({ region: process.env.AWS_REGION });
const BUCKET = process.env.S3_BUCKET;
const PROCESSED_PREFIX = process.env.PROCESSED_PREFIX || "processed/";
sasaqsasa
const streamToBuffer = async (stream) => {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
};

export const handler = async (event) => {
  console.log(`Crop Lambda activa — entorno: ${process.env.ENVIRONMENT}`);
  console.log(`Procesando ${event.Records.length} mensaje(s)`);

  const results = await Promise.allSettled(
    event.Records.map(async (record) => {
      let body;
      try {
        body = JSON.parse(record.body);
      } catch {
        throw new Error(`JSON inválido en SQS: ${record.body}`);
      }

      const s3Event = body.Records?.[0]?.s3;
      if (!s3Event) {
        console.warn("Mensaje sin evento S3:", JSON.stringify(body));
        return; 
      }

      const sourceKey = decodeURIComponent(s3Event.object.key.replace(/\+/g, " "));
      console.log(`Procesando: ${sourceKey}`);

      // Descargar imagen original
      const getRes = await s3.send(new GetObjectCommand({
        Bucket: BUCKET,
        Key: sourceKey,
      }));

      const imageBuffer = await streamToBuffer(getRes.Body);
      console.log(`Imagen descargada: ${imageBuffer.length} bytes`);

      const fileName = sourceKey.split("/").pop().replace(/\.[^.]+$/, "");
      const outputKey = `${PROCESSED_PREFIX}${fileName}_circular.png`;

      await s3.send(new PutObjectCommand({
        Bucket: BUCKET,
        Key: outputKey,
        Body: imageBuffer,
        ContentType: "image/png",
        Metadata: {
          "processed-by": "crop-lambda",
          "source-key": sourceKey,
          "environment": process.env.ENVIRONMENT,
        },
      }));

      console.log(`✅ Guardado en: s3://${BUCKET}/${outputKey}`);
    })
  );

  const failures = results
    .map((r, i) => ({ result: r, id: event.Records[i].messageId }))
    .filter(({ result }) => result.status === "rejected")
    .map(({ id, result }) => {
      console.error(`Fallo en mensaje ${id}:`, result.reason);
      return { itemIdentifier: id };
    });

  return { batchItemFailures: failures };
};