const AWS = require('aws-sdk');
const dynamo = new AWS.DynamoDB.DocumentClient();
const sqs = new AWS.SQS();

const TABLE_NAME = process.env.TABLE_NAME;

exports.handler = async (event) => {
  const { connectionId } = event.requestContext;
  console.log("[DISCONNECT]", connectionId);

  try {
    await dynamo.delete({
      TableName: TABLE_NAME,
      Key: { connectionId }
    }).promise();

    // Queue a message to the admins
    await sqs.sendMessage({
        QueueUrl: process.env.QUEUE_URL,
        MessageBody: JSON.stringify({
            type: "endConnection",
            connectionId,
            timestamp: Date.now()
        })
    }).promise();
  
    return { statusCode: 200, body: "Disconnected." };
  } catch (error) {
    console.error("Disconnect error:", error);
    return { statusCode: 500, body: "Failed to disconnect." };
  }
};