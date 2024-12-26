exports.handler = async (event) => {
    // name is either from POST or GET variables
    try {
        if (event.httpMethod === 'POST') {
            const body = JSON.parse(event.body);
            var name = body.name;
        } else {
            var name = event.queryStringParameters && event.queryStringParameters.name;
        }
    } catch (e) {
        name = 'world';
    }

    // default name
    if (!name) {
        name = 'world';
    }
    const response = {
        statusCode: 200,
        headers: {
            "Content-Type": "application/json",
            'Access-Control-Allow-Origin' : '*'
        },
        body: JSON.stringify({ message: `Hello, ${name}!` }),

    };
    return response;
};
