/* index.js */

const AWS = require('aws-sdk');
const { verifyCognitoToken } = require('./cognitoTokenVerifier');

const dynamo = new AWS.DynamoDB.DocumentClient();
//const apiGateway = new AWS.ApiGatewayManagementApi({}); 
// We'll set the endpoint dynamically once we have the callback URL

const TABLE_NAME = process.env.TABLE_NAME || 'ChatConnections'; // Make sure to set this in your Lambda's env if needed
const COGNITO_CLIENT_ID = process.env.COGNITO_CLIENT_ID;
const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID;
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const AWS_REGION = process.env.AWS_REGION;
const ADMIN_SNS_TOPIC = process.env.ADMIN_SNS_TOPIC;
const DOMAIN_NAME = process.env.DOMAIN_NAME;

// Create SNS service object
const sns = new AWS.SNS();

async function sendSMS(message) {
 const params = {
   TopicArn: ADMIN_SNS_TOPIC,
   Message: message
 };

 return new Promise(async (resolve, reject) => {
   try {
       const data = await sns.publish(params).promise();
       resolve(data); //data); // FIXME: Make SMS work
   } catch (err) {
       return reject({ message: 'Failed to send SMS', error: err });
   }
 });
}

// Helper function to send a WebSocket message to a single connection
async function sendMessage(connectionId, body, domainName) {
  try {
   return new Promise(async (resolve, reject) => {
        const client = new AWS.ApiGatewayManagementApi({ endpoint: domainName });
        // If connection isn't registered in the DB, send an error message
        // So first, we check if the connectionId is in the DB
        let connectionData;
        try {
            connectionData = await dynamo.get({
                TableName: TABLE_NAME,
                Key: {
                    connectionId
                }
            }).promise();
        } catch (err) {
            return reject('Error getting connectionId');
        }
        if (!connectionData.Item) {
            return reject(`Connection ${connectionId} not found.`);
        }

        try {
            await client.postToConnection({
                ConnectionId: connectionId,
                Data: JSON.stringify(body),
            }).promise();
            return resolve(`Message sent to ${connectionId}`);
        } catch (err) {
            // If postToConnection fails, we assume the connection is dead. Let's delete it from the DB.
            if (err.statusCode === 410) {
                console.log(`Found stale connection, deleting ${connectionId}`);
                await dynamo.delete({
                    TableName: TABLE_NAME,
                    Key: {
                        connectionId
                    }
                }).promise();
                return reject(`Found stale connection, deleted ${connectionId}`);
            } else {
                return reject(`Failed to send message to ${connectionId}: ${err.message}`);
            }
        }
    });
  } catch (err) {
    return reject(`Failed to send message to ${connectionId}: ${err.message}`);
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
      case 'set':
        return await onSet(event);
      case 'listConnections':
        return await onListConnections(event);
      case 'clientConfig':
        return { statusCode: 200, body: JSON.stringify({ response: "clientConfig", COGNITO_CLIENT_ID, COGNITO_USER_POOL_ID, GOOGLE_CLIENT_ID }) };
      default:
        return { statusCode: 400, body: JSON.stringify({ error: "default", message: 'Bad request' }) };
    }
  };

// onListConnections: list all connections in the DB (but must be an admin)
const onListConnections = async (event) => {
    const connectionId = event.requestContext.connectionId;
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
        console.error('[onListConnections] Error:', err);
        return { statusCode: 500, body: JSON.stringify({ error: "listConnections", message: 'Failed to get DB connection' }) };
    }

    if (!isAdmin) {
        return { statusCode: 403, body: JSON.stringify({ error: "listConnections", message: 'Unauthorized' }) };
    }

    try {
        const connections = await dynamo.scan({
            TableName: TABLE_NAME,
        }).promise();
        return { statusCode: 200, body: JSON.stringify({ response: "listConnections", connections: connections.Items }) };
    } catch (err) {
        console.error('[onListConnections] Error:', err);
        return { statusCode: 500, body: JSON.stringify({ error: "listConnections", message: 'Failed to list connections', trace: err.stack }) };
    }
};
// onSet: set a variable in the connection state
const onSet = async (event) => {
    const connectionId = event.requestContext.connectionId;
    const body = JSON.parse(event.body);
    const { key, value } = body;

    try {
        // As long as `key` is within ['name','email','phone'], we can set it
        if (!['fullName', 'email', 'phone'].includes(key)) {
            return { statusCode: 400, body: JSON.stringify({ error: "set", message: 'Invalid key' }) };
        }
        // As long as `value` is a string and not empty, we can set it
        if (typeof value !== 'string' || value.trim() === '') {
            return { statusCode: 400, body: JSON.stringify({ error: "set", message: 'Invalid value' }) };
        }
        // Update the connection's state in the DB
        await dynamo.update({
            TableName: TABLE_NAME,
            Key: {
                connectionId
            },
            UpdateExpression: `set ${key} = :val`,
            ExpressionAttributeValues: {
                ':val': value
            },
        }).promise();
        return { statusCode: 200, body: JSON.stringify({ response: "set", message: 'Variable set' }) };
    } catch (err) {
        console.error('[onSet] Error:', err);
        return { statusCode: 500, body: JSON.stringify({ error: "set", message: 'Failed to set variable: '+err }) };
    }
};

// get: get a variable from the connection state
const get = async (key, connectionId) => {
    try {
        const response = await dynamo.get({
            TableName: TABLE_NAME,
            Key: {
                connectionId
            }
        }).promise();
        return response.Item[key];
    } catch (err) {
        console.error('[get] Error:', err);
        return undefined;
    }
}

// onAuthenticate: verify the Cognito token
const onAuthenticate = async (event) => {
    const token = JSON.parse(event.body).accessToken;
    if (!token) {
        return { statusCode: 401, body: JSON.stringify({ error: "authenticate", message: 'Missing token' }) };
    }

    try {
        const decoded = await verifyCognitoToken(token, {
            region: AWS_REGION,
            userPoolId: COGNITO_USER_POOL_ID,
            clientId: COGNITO_CLIENT_ID,
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
        return { statusCode: 200, body: JSON.stringify({ response: "authenticate", message: 'Token valid', isAdmin, decoded }) };
    }
    catch (err) {
        return { statusCode: 401, body: JSON.stringify({ error: "authenticate", message: "Token invalid or verification error", trace: err.stack }) };
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

    // Send a message to every admin to notify them of the new connection
    const adminConnections = await dynamo.scan({
      TableName: TABLE_NAME,
      FilterExpression: "isAdmin = :adm",
      ExpressionAttributeValues: {
        ":adm": true
      }
    }).promise();
    for (const adminConnection of adminConnections.Items) {
      try {
        await sendMessage(adminConnection.connectionId, {
            action: "connect",
            fromAdmin: true,
            message: 'New connection',
            connectionId,
        }, event.requestContext.domainName, event.requestContext.stage);
      } catch (err) {
        console.error(`Failed to send message to admin ${adminConnection.connectionId}:`, err);
      }
    }

    // Send an SMS to the admin to notify them of the new connection
    try {
        const sms = sendSMS(`New connection: ${connectionId}\nGo to https://${DOMAIN_NAME}/login.html to respond.`);
    } catch (err) {
        console.error(`Failed to send SMS:`, err);
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ response: "connect", message: 'Connected.' }),
    };
  } catch (err) {
    console.error('[onConnect] DynamoDB error:', err);
    return { statusCode: 500, body: JSON.stringify({ error: "connect", message: 'Failed to connect.' }) };
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

    // Send a message to every admin to notify them of the disconnection
    const adminConnections = await dynamo.scan({
      TableName: TABLE_NAME,
      FilterExpression: "isAdmin = :adm",
      ExpressionAttributeValues: {
        ":adm": true
      }
    }).promise();
    for (const adminConnection of adminConnections.Items) {
      try {
        await sendMessage(adminConnection.connectionId, {
            action: "disconnect",
            fromAdmin: true,
            message: 'Connection disconnected',
            connectionId,
        }, event.requestContext.domainName, event.requestContext.stage);
      } catch (err) {
        console.error(`Failed to send message to admin ${adminConnection.connectionId}:`, err);
      }
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ response: "disconnect", message: 'Disconnected.' }),
    };
  } catch (err) {
    console.error('[onDisconnect] DynamoDB error:', err);
    return { statusCode: 500, body: JSON.stringify({ error: "disconnect", message: 'Failed to disconnect.' }) };
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
        return { statusCode: 400, body: JSON.stringify({ error: "sendMessage", message: 'Invalid JSON' }) };
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
        return { statusCode: 500, body: JSON.stringify({ error: "sendMessage", message: 'Failed to get DB connection' }) };
    }

    let { message, targetConnectionId } = body;
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
                // If there is a single non-admin user, query the DB for their connectionId
                const userConnections = await dynamo.scan({
                    TableName: TABLE_NAME,
                    FilterExpression: "isAdmin = :adm",
                    ExpressionAttributeValues: {
                    ":adm": false
                    }
                }).promise();
                if (userConnections.Items && userConnections.Items.length === 1) {
                    targetConnectionId = userConnections.Items[0].connectionId;
                } else {
                    return { statusCode: 400, body: JSON.stringify({ error: "sendMessage", message: 'No targetConnectionId specified' }) };
                }
            }
            // Send to the specified user
            console.log(`[onSendMessage] Admin -> ${targetConnectionId}: ${message}`);
            try {
                await sendMessage(targetConnectionId, {
                    fromAdmin: true,
                    from: connectionId,
                    message,
                    fullName: await get("fullName", connectionId),
                    email: await get("email", connectionId),
                    phone: await get("phone", connectionId),
                }, domainName, stage);
            } catch (err) {
                return { statusCode: 500, body: JSON.stringify({ error: "sendMessage", message: 'Failed to send message'+JSON.stringify(err) }) };
            }
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
                // Send an SMS to the admin to notify them of the message
                try {
                    const sms = sendSMS(`New message from ${connectionId}: ${message}\nGo to https://${DOMAIN_NAME}/login.html to respond.`);
                } catch (err) {
                    console.error(`Failed to send SMS:`, err);
                }
                // If no admin connected, handle gracefully
                return { statusCode: 200, body: JSON.stringify({ error: "sendMessage", message: "No admin is currently connected." }) };
            } else {
                // Send to the admin
                for (const adminConnection of adminConnections.Items) {
                    try {
                        await sendMessage(adminConnection.connectionId, {
                            fromAdmin: false,
                            from: connectionId,
                            message,
                            fullName: await get("fullName", connectionId),
                            email: await get("email", connectionId),
                            phone: await get("phone", connectionId),
                        }, domainName, stage);
                    } catch (err) {
                        console.error(`Failed to send message to admin ${adminConnection.connectionId}:`, err);
                    }
                }
            }
        }

        return { statusCode: 200, body: JSON.stringify({ response: "sendMessage", message: 'Message sent.' }) };
    } catch (err) {
        console.error('[onSendMessage] Error:', err);
        return { statusCode: 500, body: JSON.stringify({ error: "sendMessage", message: 'Failed to send message.' }) };
    }
};
