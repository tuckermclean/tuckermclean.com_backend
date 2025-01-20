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
