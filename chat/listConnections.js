const AWS = require('aws-sdk');
const dynamoDb = new AWS.DynamoDB.DocumentClient();

exports.handler = async (event) => {
    const params = {
        TableName: process.env.TABLE_NAME,
    };

    try {
        const data = await dynamoDb.scan(params).promise();
        const connections = data.Items.map(item => ({
            connectionId: item.connectionId,
            isAdmin: item.isAdmin
        }));

        const response = {
            statusCode: 200,
            body: JSON.stringify(connections),
        };
        return response;
    } catch (error) {
        const response = {
            statusCode: 500,
            body: JSON.stringify({ error: 'Could not fetch connections' }),
        };
        return response;
    }
};
