const AWS = require('aws-sdk');
const webPush = require('web-push'); // For generating VAPID keys
const { v4: uuidv4 } = require('uuid');
const crypto = require('crypto');

const dynamoDb = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = 'Messages';
const CONVERSATION_TABLE = 'Conversations';

// Helper function for creating a bearer token
function createBearerToken() {
    return crypto.randomBytes(64).toString('hex');
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
async function verifyBearerToken(conversationUuid, token) {
    const params = {
        TableName: CONVERSATION_TABLE,
        Key: { conversation_uuid: conversationUuid },
    };

    const result = await dynamoDb.get(params).promise();
    return result.Item?.bearer_token === token;
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

    if (!conversationUuid) {
        return response(400, { error: 'Conversation UUID is required' });
    }

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
        let authenticated_user_info = null; // FIXME: Add authentication logic
        let name, email, phone, message;
        try {
            ({ name, email, phone, message} = JSON.parse(body));
        } catch (error) {
            console.error('Error parsing message:', error);
            return response(400, { error: 'Message must be valid JSON' });
        }

        if (!(message && ((name && (email || phone)) || authenticated_user_info))) {
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
            authenticated_user_info: authenticated_user_info || null,
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
