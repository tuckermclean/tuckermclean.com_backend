/* index.js */

const AWS = require('aws-sdk');
const { verifyCognitoToken } = require('./cognitoTokenVerifier');

const dynamo = new AWS.DynamoDB.DocumentClient();
const apiGateway = new AWS.ApiGatewayManagementApi({}); 
// We'll set the endpoint dynamically once we have the callback URL

const TABLE_NAME = process.env.TABLE_NAME || 'ChatConnections'; // Make sure to set this in your Lambda's env if needed
const CLIENT_ID = process.env.CLIENT_ID;
const USER_POOL_ID = process.env.USER_POOL_ID;
const AWS_REGION = process.env.AWS_REGION;

// Helper function to send a WebSocket message to a single connection
async function sendMessage(connectionId, body, domainName, stage) {
  const endpoint = `https://${domainName}/${stage}`;
  const client = new AWS.ApiGatewayManagementApi({ endpoint });
  try {
    await client.postToConnection({
      ConnectionId: connectionId,
      Data: JSON.stringify(body),
    }).promise();
  } catch (err) {
    console.error('Error posting to connection:', err);
  }
}

exports.handler = async (event) => {
    const routeKey = event.requestContext.routeKey;

    switch (routeKey) {
      case '$connect':
        return await onConnect(event);
      case '$disconnect':
        return await onDisconnect(event);
      case 'sendMessage':
        return await onSendMessage(event);
      case 'authenticate':
        return await onAuthenticate(event);
      default:
        return { statusCode: 400, body: 'Invalid routeKey' };
    }
  };


// onAuthenticate: verify the Cognito token
const onAuthenticate = async (event) => {
    const token = JSON.parse(event.body).accessToken;
    if (!token) {
        return { statusCode: 401, body: 'Unauthorized' };
    }

    try {
        const decoded = await verifyCognitoToken(token, {
            region: AWS_REGION,
            userPoolId: USER_POOL_ID,
            clientId: CLIENT_ID,
        });
        // If decoded.cognito:groups contains "admin", you can set isAdmin to true
        let isAdmin = false;
        // If is admin, flag the connection in the DB
        if (decoded["cognito:groups"] && decoded["cognito:groups"].includes("admin")) {
            isAdmin = true;
            await dynamo.put({
                TableName: TABLE_NAME,
                Item: {
                    connectionId: event.requestContext.connectionId,
                    isAdmin,
                },
            }).promise();
        }
        return { statusCode: 200, body: JSON.stringify({ message: 'Token valid', isAdmin, decoded }) };
    }
    catch (err) {
        return { statusCode: 401, body: JSON.stringify({ error: JSON.stringify(err.stack), lol: "lol"}) };
    }
};

// onConnect: add connection to DynamoDB
const onConnect = async (event) => {
  const connectionId = event.requestContext.connectionId;
  console.log('[onConnect] connectionId:', connectionId);

  try {
    await dynamo.put({
      TableName: TABLE_NAME,
      Item: {
        connectionId: connectionId,
        // you could store more info here, like a userId or role
        // For example, if you'd identify admin vs. visitor, you'd do it here
        isAdmin: false, 
      },
    }).promise();

    return {
      statusCode: 200,
      body: 'Connected.',
    };
  } catch (err) {
    console.error('[onConnect] DynamoDB error:', err);
    return { statusCode: 500, body: 'Failed to connect.' };
  }
};

// onDisconnect: remove connection from DynamoDB
const onDisconnect = async (event) => {
  const connectionId = event.requestContext.connectionId;
  console.log('[onDisconnect] connectionId:', connectionId);

  try {
    await dynamo.delete({
      TableName: TABLE_NAME,
      Key: {
        connectionId: connectionId,
      },
    }).promise();

    return {
      statusCode: 200,
      body: 'Disconnected.',
    };
  } catch (err) {
    console.error('[onDisconnect] DynamoDB error:', err);
    return { statusCode: 500, body: 'Failed to disconnect.' };
  }
};

// onSendMessage: main message handling
const onSendMessage = async (event) => {
    const connectionId = event.requestContext.connectionId;
    const domainName   = event.requestContext.domainName;
    const stage        = event.requestContext.stage;

    let body;
    try {
        body = JSON.parse(event.body);
    } catch (err) {
        console.error('Invalid JSON:', event.body);
        return { statusCode: 400, body: 'Invalid request body' };
    }

    let isAdmin = false;

    // isAdmin is set to true if the sender's connection is an admin in the DB
    try {
        let response = await dynamo.get({
            TableName: TABLE_NAME,
            Key: {
                connectionId
            }
        }).promise();
        isAdmin = response.Item.isAdmin;
    } catch (err) {
        console.error('[onSendMessage] Error:', err);
        return { statusCode: 500, body: 'Failed to get DB connection' };
    }

    const { message, targetConnectionId } = body;
    /*
        We might define a simple protocol, for example:
        {
        "action": "sendMessage",
        "message": "hello world",
        "targetConnectionId": "xyz123",  // optional
        "isAdmin": true // or false
        }
        If isAdmin == true, we interpret the message as the admin sending to a user
        If isAdmin == false, we interpret the message as a user sending to the admin
    */

    // If the user is not the admin, we want to forward the message to the admin.
    // If the user is the admin, we want to send the message to a specific user.
    // This means you, as the admin, must specify the `targetConnectionId` of the user you want to message.

    try {
        if (isAdmin) {
            // Admin is sending a message. Must have a targetConnectionId.
            if (!targetConnectionId) {
                return { statusCode: 400, body: 'Missing targetConnectionId for admin message' };
            }
            // Send to the specified user
            console.log(`[onSendMessage] Admin -> ${targetConnectionId}: ${message}`);
            await sendMessage(targetConnectionId, { fromAdmin: true, message }, domainName, stage);
        } else {
            // A user is sending to the admin. We'll find the admin's connection ID(s). 
            // If there's only one admin, you can store or find it. For simplicity, let's assume there's only 1 admin connected 
            // with isAdmin = true. Or you can store the admin ID some other way.
            console.log(`[onSendMessage] Visitor -> Admin: ${message}`);

            // Query the DB for the admin's connection
            const adminConnections = await dynamo.scan({
                TableName: TABLE_NAME,
                FilterExpression: "isAdmin = :adm",
                ExpressionAttributeValues: {
                ":adm": true
                }
            }).promise();

            if (!adminConnections.Items || adminConnections.Items.length === 0) {
                // If no admin connected, handle gracefully
                return { statusCode: 200, body: 'No admin currently connected.' };
            } else {
                // Send to the admin
                for (const adminConnection of adminConnections.Items) {
                    await sendMessage(adminConnection.connectionId, { fromAdmin: false, message }, domainName, stage);
                }
            }
        }

        return { statusCode: 200, body: 'Message sent' };
    } catch (err) {
        console.error('[onSendMessage] Error:', err);
        return { statusCode: 500, body: 'Failed to send message.' };
    }
};
