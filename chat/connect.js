const AWS = require('aws-sdk');
const dynamo = new AWS.DynamoDB.DocumentClient();
const sqs = new AWS.SQS();

const TABLE_NAME = process.env.TABLE_NAME;

exports.handler = async (event) => {
  const { connectionId } = event.requestContext;
  console.log("[CONNECT]", connectionId);

  const { accessToken } = event.queryStringParameters || {};
  if (accessToken) {
    console.log("Got access token:", accessToken);
    const { verifyCognitoToken } = require('./cognitoTokenVerifier');
    try {
      const decoded = await verifyCognitoToken(accessToken);
      // if "admin" is in the cognito:groups, we'll treat them as an admin
      if (decoded['cognito:groups'] && decoded['cognito:groups'].includes('admin')) {
        // There might be queue messages in the dead letter queue, kick them back to the main queue
        await redriveDLQ();
        return commit({ connectionId, isAdmin: true });
      } else {
        return commit({ connectionId, isAdmin: false });
      }
    } catch (error) {
      console.error("Access token verification failed:", error);
      return commit({ connectionId, isAdmin: false });
    }
  } else {
    return commit({ connectionId, isAdmin: false });
  }
};

async function commit({ connectionId, isAdmin }) {
  try {
    await dynamo.put({
      TableName: TABLE_NAME,
      Item: {
        connectionId,
        isAdmin,
      }
    }).promise();

    // Queue a message to the admins
    await sqs.sendMessage({
      QueueUrl: process.env.QUEUE_URL,
      MessageBody: JSON.stringify({
        type: "newConnection",
        connectionId,
        timestamp: Date.now()
      })
    }).promise();

    // Queue a message to the user
    await sqs.sendMessage({
      QueueUrl: process.env.QUEUE_URL,
      MessageBody: JSON.stringify({
        type: "welcome",
        connectionId,
        isAdmin,
      })
    }).promise();

    if (isAdmin) {
      console.log("Connected as admin");
      return { statusCode: 200, body: `Connected as admin.` };
    } else {
      console.log("Connected as guest");
      return { statusCode: 200, body: "Connected." };
    }
  } catch (error) {
    console.error("Connect error:", error);
    return { statusCode: 500, body: "Failed to connect." };
  }
}

/**
 * Manual redrive function:
 * 1. Receive messages from DLQ (in batches).
 * 2. Send them to the main queue.
 * 3. Delete them from DLQ.
 * Repeat until DLQ is empty.
 */
async function redriveDLQ() {
  while (true) {
    const resp = await sqs.receiveMessage({
      QueueUrl: process.env.DLQ_QUEUE_URL,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 0 // no long polling
    }).promise();

    if (!resp.Messages || resp.Messages.length === 0) {
      console.log("DLQ is empty. Done redriving.");
      break;
    }

    for (const msg of resp.Messages) {
      try {
        // 1. Re-publish to main queue
        await sqs.sendMessage({
          QueueUrl: process.env.QUEUE_URL,
          MessageBody: msg.Body
        }).promise();

        // 2. Delete from DLQ
        await sqs.deleteMessage({
          QueueUrl: process.env.DLQ_QUEUE_URL,
          ReceiptHandle: msg.ReceiptHandle
        }).promise();

        console.log("Redriven message ID:", msg.MessageId);
      } catch (err) {
        console.error("Failed to redrive message ID:", msg.MessageId, err);
        // If we fail, you might break or continue. 
        // But typically you don't want an infinite loop, so handle carefully.
      }
    }
  }
}
