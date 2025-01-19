const { verifyCognitoToken } = require('./cognitoTokenVerifier');

exports.handler = async (event) => {
  /*
    event structure for HTTP API custom Lambda authorizer in API Gateway v2 might look like:
    {
      type: "REQUEST",
      headers: {
        Authorization: "Bearer eyJra..."
      },
      routeArn: "...",
      ...
    }
  */
  try {
    console.log("event.headers:", JSON.stringify(event.headers));
    const token = event.headers?.authorization?.split(' ')[1]; // if "Bearer <token>"
    if (!token) {
      console.log("[DENY] no token")
      return generatePolicy("anonymous", "Deny", event.routeArn);
    }

    // Verify
    const decoded = await verifyCognitoToken(token);

    // Optional: Check if user is really an admin
    if (!decoded["cognito:groups"] || !decoded["cognito:groups"].includes("admin")) {
      console.log("[DENY] not an admin")
      return generatePolicy("user", "Deny", event.routeArn);
    }

    // Allowed
    console.log("[ALLOW] admin")
    return generatePolicy("admin", "Allow", event.routeArn);
  } catch (err) {
    console.error("Auth error:", err);
    return generatePolicy("anonymous", "Deny", event.routeArn);
  }
};

function generatePolicy(principalId, effect, resource) {
  return {
    principalId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [
        {
          Action: "execute-api:Invoke",
          Effect: effect,
          Resource: resource,
        },
      ],
    },
  };
}
