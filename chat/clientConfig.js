const AWS = require('aws-sdk');

exports.handler = async (event) => {
    const response = {
        statusCode: 200,
        body: JSON.stringify({
            COGNITO_CLIENT_ID: process.env.COGNITO_CLIENT_ID,
            COGNITO_USER_POOL_ID: process.env.COGNITO_USER_POOL_ID,
            GOOGLE_CLIENT_ID: process.env.GOOGLE_CLIENT_ID,
        }),
    };
    return response;
};
