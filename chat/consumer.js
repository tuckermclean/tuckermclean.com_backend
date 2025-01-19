const AWS = require('aws-sdk');
const dynamo = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = process.env.TABLE_NAME || "ChatConnections";
const failures = [];

exports.handler = async (event) => {
  for (const record of event.Records) {
    // Each SQS message is in record.body
    const body = JSON.parse(record.body);
    try {
      await processMessage(body);
    } catch (err) {
      console.error("Error processing message:", err);
      failures.push({ itemIdentifier: record.messageId });
    }
  }

  return {
    statusCode: 200,
    batchItemFailures: failures, 
    body: JSON.stringify({ status: "Messages processed" }),
  };
};

/**
 * Dispatch each message to the right recipients over WebSocket.
 * E.g. "guestMessage" -> push to all admins; "adminMessage" -> push to that visitor.
 */
async function processMessage(args) {
  if (args.type === "guestMessage" || args.type === "newConnection" || args.type === "endConnection") {
    // Send the guest message to all admin connections
    await postToAdmins(
      { fromAdmin: false, ...args }
    );
  }
  else if (args.type === "welcome" || args.type === "adminMessage") {
    // Send the admin message to a specific visitor.
    // Assume your table items store visitorId so you can find them:
    const visitorConnection = await findVisitorConnection(args.targetConnectionId || args.connectionId);
    if (!visitorConnection) {
      console.log(`Visitor not connected or not found for ID: ${args.targetConnectionId || args.connectionId}`);
      return;
    }

    await postToConnection(
      visitorConnection.connectionId,
      { fromAdmin: true, ...args }
    );
  }
  else {
    console.warn("Unknown message type:", args.type);
  }
}

/**
 * Helper to return true if the connectionId is in the table.
 */
async function findVisitorConnection(connectionId) {
  const result = await dynamo.get({
    TableName: TABLE_NAME,
    Key: { connectionId },
  }).promise();

  return result.Item;
}

/**
 * Helper to post a message to a WebSocket connection. 
 * If we get a 410 error, we remove the stale connection from DynamoDB.
 */
async function postToConnection(connectionId, payload) {
  // 28sbkickxh.execute-api.us-west-2.amazonaws.com
  const endpoint = `${process.env.API_WS_ID}.execute-api.${process.env.AWS_REGION}.amazonaws.com/${process.env.API_WS_STAGE}`;
  const apigw = new AWS.ApiGatewayManagementApi({ endpoint });

  try {
    await apigw.postToConnection({
      ConnectionId: connectionId,
      Data: JSON.stringify(payload),
    }).promise();
    console.log(`Delivered to ${connectionId} ${JSON.stringify(payload)}`);
  } catch (err) {
    if (err.statusCode === 410) {
      console.log(`Stale connection, removing ${connectionId}`);
      await dynamo.delete({
        TableName: TABLE_NAME,
        Key: { connectionId },
      }).promise();
    } else {
      console.error(`Failed to postToConnection for ${connectionId}:`, err);
      throw err;
    }
  }
}


/**
 * Helper to post a message to all admin connections.
 */
async function postToAdmins(args) {
  const admins = await dynamo.scan({
    TableName: TABLE_NAME,
    FilterExpression: "isAdmin = :adm",
    ExpressionAttributeValues: { ":adm": true },
  }).promise();

  // If there are 0 admins, we can't send the message
  if (!admins.Items || admins.Items.length === 0) {
    // Send a message to the guest if it's the first time this message has been processed
    await postToConnection(args.connectionId, { type: "noAdmins", ...args });
    throw new Error(`No admins connected: ${JSON.stringify(args)}`);
  } else {
      for (const admin of admins.Items) {
        await postToConnection(admin.connectionId, { connectionId: admin.connectionId, ...args });
      }
  }
}