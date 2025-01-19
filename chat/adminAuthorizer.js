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
    console.log("event:", JSON.stringify(event, null, 2));
    const authHeader = event.headers?.authorization;
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      console.log("[DENY] Authorization header missing or invalid");
      return generatePolicy("anonymous", "Deny", event.routeArn);
    }
    const token = authHeader.split(" ")[1];
    if (!token) {
      console.log("[DENY] no token")
      return generatePolicy("anonymous", "Deny", event.routeArn);
    }
    
    // Verify
    try {
      const decoded = await verifyCognitoToken(token);
      console.log("Decoded token:", decoded);
      const groups = decoded["cognito:groups"] || [];
      console.log("User groups:", groups);
      if (!groups.includes("admin")) {
        console.log("[DENY] User not in admin group");
        return generatePolicy(decoded.sub || "user", "Deny", event.routeArn);
      }
    } catch (err) {
      console.error("[DENY] Token verification failed:", err.message);
      return generatePolicy("anonymous", "Deny", event.routeArn);
    }
    
    // Allowed
    console.log("[ALLOW] admin")
    const resource = event.routeArn || "*";
    return generatePolicy("admin", "Allow", resource);
  } catch (err) {
    console.error("[DENY] Auth error:", err);
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
