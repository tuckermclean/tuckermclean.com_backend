const AWS = require('aws-sdk');
const sqs = new AWS.SQS();

const QUEUE_URL = process.env.QUEUE_URL || ""; // The SQS queue we push all messages to

/**
 * This Lambda:
 *   - Handles POST /message  (no authorizer)
 *   - Handles POST /adminMessage (protected by authorizer)
 * Based on the path or authorizer context, we do different logic.
 */
exports.handler = async (event) => {
  // For HTTP APIs (APIGateway v2), the path is in event.requestContext.http.path
  // For REST APIs (APIGateway v1), the path might be event.resource or event.path
  const path = event.path;
  
  console.log("Received path: ", JSON.stringify(path));

  // Parse body if needed
  let body;
  try {
    body = JSON.parse(event.body);
  } catch (err) {
    console.error("Invalid JSON", err);
    return {
      statusCode: 400,
      body: JSON.stringify({ error: `Invalid JSON body: ${body}` }),
    };
  }

  // We'll handle:
  //   POST /message -> treat as guest
  //   POST /adminMessage -> treat as admin
  if (path === "/message") {
    // Guest
    return await handleGuestMessage(body);
  } 
  else if (path === "/adminMessage") {
    // Admin route - if there's an authorizer, we can check it
    // or just trust that the authorizer blocked unauthorized requests
    return await handleAdminMessage(body, event);
  } 
  else {
    return {
      statusCode: 404,
      body: JSON.stringify({ error: `Not found, ${path}` }),
    };
  }
};

/**
 * Handle a guest message: no auth required
 */
async function handleGuestMessage(body) {
  const { message, connectionId, name, email, phone } = body;
  if (!message || !connectionId) {
    return { statusCode: 400, body: JSON.stringify({ error: "Message and connectionId required" }) };
  }

  // Enqueue as a "guestMessage"
  await sqs.sendMessage({
    QueueUrl: QUEUE_URL,
    MessageBody: JSON.stringify({
      type: "guestMessage",
      connectionId,
      message,
      name,
      email,
      phone,
      timestamp: new Date().toISOString(),
    })
  }).promise();

  return {
    statusCode: 200,
    body: JSON.stringify({ status: "Guest message queued" }),
  };
}

/**
 * Handle an admin message: presumably protected by an authorizer
 */
async function handleAdminMessage(body, event) {
  const { message, targetConnectionId, name, email, phone } = body;
  if (!message || !targetConnectionId) {
    return { statusCode: 400, body: JSON.stringify({
      error: "message and targetConnectionId are required for admin message"
    })};
  }

  // If using a custom authorizer or Cognito, we can check claims in event.requestContext.authorizer
  // E.g. event.requestContext.authorizer.jwt or something similar
  // But since we've presumably let the request through, they're already authorized.

  // Enqueue as an "adminMessage"
  await sqs.sendMessage({
    QueueUrl: QUEUE_URL,
    MessageBody: JSON.stringify({
      type: "adminMessage",
      targetConnectionId,
      message,
      name,
      email,
      phone,
      timestamp: new Date().toISOString(),
    })
  }).promise();

  return {
    statusCode: 200,
    body: JSON.stringify({ status: "Admin message queued" }),
  };
}
