const AWS = require('aws-sdk');
const { v4: uuidv4 } = require('uuid'); // For generating message IDs
const dynamoDb = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = 'Messages';

exports.handler = async (event) => {
    const { httpMethod, pathParameters, body } = event;
    const conversationUuid = pathParameters?.uuid;

    if (!conversationUuid) {
        return {
            statusCode: 400,
            body: JSON.stringify({ error: 'Conversation UUID is required' }),
        };
    }

    if (httpMethod === 'GET') {
        // Retrieve all messages for the conversation
        const params = {
            TableName: TABLE_NAME,
            KeyConditionExpression: 'conversation_uuid = :uuid',
            ExpressionAttributeValues: {
                ':uuid': conversationUuid,
            },
            ScanIndexForward: true, // Sort by timestamp ascending
        };

        try {
            const result = await dynamoDb.query(params).promise();
            return {
                statusCode: 200,
                body: JSON.stringify(result.Items),
            };
        } catch (error) {
            console.error('Error querying messages:', error);
            return {
                statusCode: 500,
                body: JSON.stringify({ error: 'Could not retrieve messages' }),
            };
        }
    } else if (httpMethod === 'POST') {
        // Add a new message to the conversation
        const { sender, message, authenticated_user_info } = JSON.parse(body);

        if (!message || (!sender && !authenticated_user_info)) {
            return {
                statusCode: 400,
                body: JSON.stringify({ error: 'Sender or authenticated user info and message are required' }),
            };
        }

        const newMessage = {
            conversation_uuid: conversationUuid,
            message_id: uuidv4(),
            timestamp: new Date().toISOString(),
            sender,
            message,
            authenticated_user_info: authenticated_user_info || null,
        };

        const params = {
            TableName: TABLE_NAME,
            Item: newMessage,
        };

        try {
            await dynamoDb.put(params).promise();
            return {
                statusCode: 201,
                body: JSON.stringify({ message: 'Message added', newMessage }),
            };
        } catch (error) {
            console.error('Error adding message:', error);
            return {
                statusCode: 500,
                body: JSON.stringify({ error: 'Could not add message' }),
            };
        }
    } else {
        return {
            statusCode: 405,
            body: JSON.stringify({ error: 'Method not allowed' }),
        };
    }
};
