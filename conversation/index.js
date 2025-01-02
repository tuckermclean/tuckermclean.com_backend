const AWS = require('aws-sdk');
const webPush = require('web-push'); // For generating VAPID keys
const { v4: uuidv4 } = require('uuid');
const crypto = require('crypto');

const dynamoDb = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = 'Messages';
const CONVERSATION_TABLE = 'Conversations';
const ADMIN_TOKENS_TABLE = 'AdminTokens';

let authenticated_user_info = undefined; // Until admin user logs in

// Helper function for creating a bearer token
function createBearerToken() {
    return crypto.randomBytes(64).toString('base64');
}

// Helper function for VAPID keys
function generateVAPIDKeys() {
    const keys = webPush.generateVAPIDKeys();
    return {
        publicKey: keys.publicKey,
        privateKey: keys.privateKey,
    };
}

// Helper function for verifying the bearer token
async function verifyBearerToken(conversationUuid = null, token) {
    const params = {
        TableName: CONVERSATION_TABLE,
        Key: { conversation_uuid: conversationUuid },
    };

    const result = await dynamoDb.get(params).promise();
    if (result.Item?.bearer_token === token) {
        authenticated_user_info = undefined;
        return true;
    } else {
        // Check if the token is in the admin keys table
        const adminTokens = await dynamoDb.get({
            TableName: ADMIN_TOKENS_TABLE,
            Key: { bearer_token: token },
        }).promise();
        if (adminTokens.Item?.bearer_token === token) {
            authenticated_user_info = adminTokens.Item?.name || "Admin";
            return true;
        } else {
            authenticated_user_info = undefined;
            return false;
        }
    }
}

// Standard response function
function response(statusCode, body, headers = {}) {
    headers = {
        ...headers,
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*", // Adjust for your security needs
    };
    return {
        statusCode,
        headers,
        body: JSON.stringify(body),
    };
}

exports.handler = async (event) => {
    const { httpMethod, pathParameters, headers, body, queryStringParameters } = event;
    const conversationUuid = pathParameters?.uuid;

    if (httpMethod === 'GET') {
        // Handle "new" conversation creation
        if (conversationUuid === 'new') {
            const newUuid = uuidv4();
            const bearerToken = createBearerToken();
            const vapidKeys = generateVAPIDKeys();

            const newConversation = {
                conversation_uuid: newUuid,
                bearer_token: bearerToken,
                vapid_public_key: vapidKeys.publicKey,
                vapid_private_key: vapidKeys.privateKey,
                created_at: new Date().toISOString(),
            };

            try {
                await dynamoDb.put({
                    TableName: CONVERSATION_TABLE,
                    Item: newConversation,
                }).promise();

                return response(201, {
                    message: 'New conversation created',
                    conversation_uuid: newUuid,
                    bearer_token: bearerToken,
                    vapid_public_key: vapidKeys.publicKey,
                });
            } catch (error) {
                console.error('Error creating conversation:', error);
                return response(500, { error: 'Could not create conversation' });
            }
        } else if (conversationUuid === 'admin') {
            // Authenticate admin user against a username and password stored in Secrets Manager
            let secret;
            try {
                const secretsManager = new AWS.SecretsManager();
                const data = await secretsManager.getSecretValue({ SecretId: "ADMIN_USER_PASS" }).promise();
                secret = data.SecretString;
            } catch (err) {
                if (err.code === "ResourceNotFoundException") {
                    // Secret doesn't exist, can't authenticate
                    return response(401, { error: 'Invalid admin credentials' });
                }
                throw err;
            }

            const authString = Buffer.from(headers?.Authorization?.split('Basic ')[1], 'base64').toString();
            // Split the auth string into username and password
            const [username, password, name] = secret.split(':');
            if (`${username}:${password}` !== authString) {
                return response(401, { error: 'Invalid admin credentials' });
            } else {
                // Generate a bearer token for the admin user
                const bearerToken = createBearerToken();
                const newAdminToken = {
                    bearer_token: bearerToken,
                    name: name || "Admin",
                };

                try {
                    await dynamoDb.put({
                        TableName: ADMIN_TOKENS_TABLE,
                        Item: newAdminToken,
                    }).promise();

                    return response(201, {
                        message: 'Admin authenticated',
                        name: name || "Admin",
                        bearer_token: bearerToken,
                    });
                } catch (error) {
                    console.error('Error creating admin token:', error);
                    return response(500, { error: 'Could not authenticate admin', data: error });
                }
            }
        } else if (!conversationUuid) {
            // If authenticated user is an admin, return list of all conversations, otherwise return 400
            if (typeof(authenticated_user_info) !== 'undefined') {
                // Only return conversation_uuid and vapid_public_key
                const params = {
                    TableName: CONVERSATION_TABLE,
                    ProjectionExpression: 'conversation_uuid, vapid_public_key',
                };
                try {
                    const result = await dynamoDb.scan(params).promise();
                    return response(200, result.Items);
                } catch (error) {
                    console.error('Error listing conversations:', error);
                    return response(500, { error: 'Could not list conversations', data: error});
                }
            } else {
                return response(400, { error: 'Conversation UUID is required' });
            }

        } else {
            // Verify the bearer token for an existing conversation
            const token = headers?.Authorization?.split('Bearer ')[1];
            const verified = await verifyBearerToken(conversationUuid, token);
            if (!verified) {
                return response(401, { error: 'Invalid bearer token' });
            }
        }
        // Retrieve messages for an existing conversation
        const since = event.queryStringParameters?.since;
        let params;
        if (since) {
            params = {
                TableName: TABLE_NAME,
                KeyConditionExpression: 'conversation_uuid = :uuid AND #ts > :since',
                ExpressionAttributeNames: {
                    '#ts': 'timestamp', // Use ExpressionAttributeNames to handle reserved keywords
                },
                ExpressionAttributeValues: {
                    ':uuid': conversationUuid,
                    ':since': since,
                },
                ScanIndexForward: false, // Retrieve newest messages first
            };
        } else {
            // Retrieve all messages for the conversation
            params = {
                TableName: TABLE_NAME,
                KeyConditionExpression: 'conversation_uuid = :uuid',
                ExpressionAttributeValues: {
                    ':uuid': conversationUuid,
                },
                ScanIndexForward: false, // Retrieve newest messages first
            };
        }

        try {
            const result = await dynamoDb.query(params).promise();
            return response(200, result.Items.reverse()); // Reverse the order to get oldest messages first
        } catch (error) {
            // If error is due to UUID not existing, return 404
            if (error.code === 'ResourceNotFoundException') {
                return response(404, { error: 'Conversation not found' });
            }
            console.error('Error querying messages:', error);
            return response(500, { error: 'Could not retrieve messages' });
        }
    } else if (httpMethod === 'POST') {
        // Verify the bearer token for an existing conversation
        const token = headers?.Authorization?.split('Bearer ')[1];
        const verified = await verifyBearerToken(conversationUuid, token);
        if (!verified) {
            return response(401, { error: 'Invalid bearer token' });
        }

        // Add a new message to the conversation
        let name, email, phone, message;
        try {
            ({ name, email, phone, message} = JSON.parse(body));
        } catch (error) {
            console.error('Error parsing message:', error);
            return response(400, { error: 'Message must be valid JSON' });
        }

        if (!(message && ((name && (email || phone)) || typeof(authenticated_user_info) !== 'undefined'))) {
            return response(400, { error: 'Message, and contact info or authentication are required' });
        }

        const newMessage = {
            conversation_uuid: conversationUuid,
            message_id: uuidv4(),
            timestamp: new Date().toISOString(),
            name,
            email,
            phone,
            message,
            authenticated_user_info: authenticated_user_info,
        };

        try {
            await dynamoDb.put({
                TableName: TABLE_NAME,
                Item: newMessage,
            }).promise();

            return response(201, { message: 'Message added', newMessage });
        } catch (error) {
            console.error('Error adding message:', error);
            return response(500, { error: 'Could not add message' });
        }
    // Else if method is OPTIONS, return CORS headers
    } else if (httpMethod === 'OPTIONS') {
        return response (200, {}, {
            "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type",
        });
    } else {
        return response(405, { error: 'Method not allowed' });
    }
};
