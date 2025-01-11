/**
 * Usage:
 *   const { verifyCognitoToken } = require('./cognitoTokenVerifier');
 * 
 *   exports.handler = async (event) => {
 *     const token = event.headers.Authorization; // or however you get the token
 *     try {
 *       const decoded = await verifyCognitoToken(token, {
 *         region: 'us-east-1',
 *         userPoolId: 'us-east-1_ABC123',
 *         clientId: 'YOUR_APP_CLIENT_ID' // optional if you want to validate audience
 *       });
 *       // Token is valid, do something with decoded payload
 *       return { statusCode: 200, body: JSON.stringify({ message: 'Token valid', decoded }) };
 *     } catch (err) {
 *       // Token invalid or verification error
 *       return { statusCode: 401, body: JSON.stringify({ error: err.message }) };
 *     }
 *   };
 */

const https = require('https');
const jwt = require('jsonwebtoken');
const jwkToPem = require('jwk-to-pem');

/**
 * Verify a Cognito-signed JWT (access or ID token).
 * @param {string} token - The JWT to verify.
 * @param {object} options
 * @param {string} options.region     - AWS region of the User Pool (e.g., 'us-east-1').
 * @param {string} options.userPoolId - ID of the User Pool (e.g., 'us-east-1_ABC123').
 * @param {string} [options.clientId] - (Optional) Cognito App Client ID if you want to validate `aud`.
 * @return {Promise<object>} Decoded token payload if valid; otherwise throws an error.
 */
async function verifyCognitoToken(token, { region, userPoolId, clientId }) {
  if (!token) {
    throw new Error('Missing token');
  }

  // 1. Decode header to find the kid
  const decodedHeader = jwt.decode(token, { complete: true });
  if (!decodedHeader || !decodedHeader.header || !decodedHeader.header.kid) {
    throw new Error('Invalid token header');
  }

  // 2. Construct the Issuer and JWKS URI
  const issuer = `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`;
  const jwksUri = `${issuer}/.well-known/jwks.json`;

  // 3. Fetch JWKS
  const jwks = await fetchJwks(jwksUri);

  // 4. Find the matching key by kid
  const { kid } = decodedHeader.header;
  const jwk = jwks.find(key => key.kid === kid);
  if (!jwk) {
    throw new Error('JWK not found for kid');
  }

  // 5. Convert to PEM
  const pem = jwkToPem(jwk);

  // 6. Verify using jsonwebtoken
  return new Promise((resolve, reject) => {
    const verifyOptions = {
      issuer,
      // If you want to validate the audience claim, set it here:
      audience: undefined // Can't validate audience because Cognito doesn't provide `aud`
                          // for access tokens.                      clientId || undefined
    };

    jwt.verify(token, pem, verifyOptions, (err, decodedPayload) => {
        if (err) {
            return reject(new Error(`Token verification failed: ${err.message}`));
        }
        resolve( decodedPayload );
    });
  });
}

/**
 * Helper to fetch JWKS from Cognito
 */
function fetchJwks(jwksUri) {
  return new Promise((resolve, reject) => {
    https.get(jwksUri, resp => {
      let data = '';
      resp.on('data', chunk => { data += chunk; });
      resp.on('end', () => {
        try {
          const body = JSON.parse(data);
          if (!body.keys) {
            return reject(new Error('Invalid JWKS response'));
          }
          resolve(body.keys);
        } catch (error) {
          reject(error);
        }
      });
    }).on('error', err => {
      reject(err);
    });
  });
}

module.exports = {
    verifyCognitoToken,
};
