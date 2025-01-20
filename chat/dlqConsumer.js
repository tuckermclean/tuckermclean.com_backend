const AWS = require('aws-sdk');
const dynamo = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = process.env.TABLE_NAME || "ChatConnections";

// We'll collect failures for each SQS record by its messageId.
exports.handler = async (event) => {
  const batchFailures = [];
  
  // Process each message in the batch.
  for (const record of event.Records) {
    const body = JSON.parse(record.body);
    try {
      // Process each message. If any message should be retried (or DLQed), 
      // throw an error or explicitly push its messageId into batchFailures.
      await processMessage(body);
    } catch (err) {
      console.error("Error processing message:", err);
      // Mark this record as failure so that it is not removed from SQS.
      batchFailures.push({ itemIdentifier: record.messageId });
    }
  }

  // Return the partial batch response: records in batchFailures will be retried.
  return {
    batchItemFailures: batchFailures,
  };
};

/**
 * Process the message based on its type.
 * For guest messages (or connection events), attempt to send to all admin connections.
 * For admin messages (or welcome) send to the target visitor.
 * If no admin is available for a guestMessage, we attempt to send a 'noAdmins' message to the originating connection,
 * then throw an error so that this record is marked as failed (and eventually sent to the DLQ).
 */
async function processMessage(args) {
  if (args.type === "guestMessage") {
    // Send guest messages to all admin connections.
    // postToAdmins is expected to throw if no admin is available.
    await postToAdmins({ fromAdmin: false, ...args });
  }
  else {
    console.warn("Dropping message: ", args.type);
    // Optionally, you could decide to treat unknown message types as success or failure.
    // Here, we'll assume success.
  }
}

/**
 * Helper to send a message to a specific WebSocket connection.
 * On a 410 error (stale connection) the connection is removed.
 */
async function postToConnection(connectionId, payload) {
  const endpoint = `${process.env.API_WS_ID}.execute-api.${process.env.AWS_REGION}.amazonaws.com/${process.env.API_WS_STAGE}`;
  const apigw = new AWS.ApiGatewayManagementApi({ endpoint });
  
  try {
    await apigw.postToConnection({
      ConnectionId: connectionId,
      Data: JSON.stringify(payload),
    }).promise();
    console.log(`Delivered to ${connectionId}: ${JSON.stringify(payload)}`);
  } catch (err) {
    if (err.statusCode === 410) {
      console.log(`Stale connection, removing ${connectionId}`);
      await dynamo.delete({
        TableName: TABLE_NAME,
        Key: { connectionId },
      }).promise();
    } else {
      console.error(`Failed to postToConnection for ${connectionId}:`, err);
      // Re-throw error to mark this SQS message as failed.
      throw err;
    }
  }
}

/**
 * Helper to post a message to all admin connections.
 * If no admins are available, send a "noAdmins" message to the sender and then throw an error.
 */
async function postToAdmins(args) {
  const admins = await dynamo.scan({
    TableName: TABLE_NAME,
    FilterExpression: "isAdmin = :adm",
    ExpressionAttributeValues: { ":adm": true },
  }).promise();

  if (!admins.Items || admins.Items.length === 0) {
    // No admins connected.
    console.log(`No admins available for message from ${args.connectionId}`);
    // Throw an error so that this message is not deleted but instead moves to the DLQ.
    throw new Error(`No admins available for message: ${JSON.stringify(args)}`);
  } else {
    for (const admin of admins.Items) {
      // Post the message to each admin.
      await postToConnection(admin.connectionId, { ...args });
    }
  }
}
