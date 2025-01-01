const AWS = require('aws-sdk');
const { v4: uuidv4 } = require('uuid'); // For generating message IDs
const dynamoDb = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = 'Messages';
const credential = "user:pass"; // FIXME: Will not be used in production

function verifyAuth(headers) {
    const auth = headers?.Authorization;
    if (!auth) {
        return false;
    }

    const encoded = auth.split(' ')[1];
    const decoded = Buffer.from(encoded, 'base64').toString();
    return decoded === credential;
}

function response(statusCode, body, headers = {}) {
    headers = {
        ...headers,
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*", // Adjust for your security needs
    };
    return {
        statusCode,
        headers: headers,
        body: JSON.stringify(body),
    };
}

exports.handler = async (event) => {
    const { httpMethod, pathParameters, headers, body } = event;
    const conversationUuid = pathParameters?.uuid;

    if (!conversationUuid) {
        return response(400, { error: 'Conversation UUID is required' });
    }

    if (headers && verifyAuth(headers)) {
        authenticated_user_info = credential.split(":")[0];
    } else {
        authenticated_user_info = undefined;
    }

    if (httpMethod === 'GET') {
        // If client has provided a "since" query parameter, retrieve messages since that timestamp
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
            console.error('Error querying messages:', error);
            return response(500, { error: 'Could not retrieve messages' });
        }
    } else if (httpMethod === 'POST') {
        // Add a new message to the conversation
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

        const params = {
            TableName: TABLE_NAME,
            Item: newMessage,
        };

        try {
            await dynamoDb.put(params).promise();
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
