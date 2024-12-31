const AWS = require("aws-sdk");
const webpush = require("web-push");

// AWS Secrets Manager client
const secretsManager = new AWS.SecretsManager();

// Secret names
const VAPID_PUBLIC_SECRET = "VAPID_PUBLIC_KEY";
const VAPID_PRIVATE_SECRET = "VAPID_PRIVATE_KEY";

async function getSecret(secretName) {
    try {
        const data = await secretsManager.getSecretValue({ SecretId: secretName }).promise();
        return data.SecretString;
    } catch (err) {
        if (err.code === "ResourceNotFoundException") {
            return null;
        }
        throw err;
    }
}

async function storeSecret(secretName, secretValue) {
    try {
        await secretsManager.createSecret({
            Name: secretName,
            SecretString: secretValue,
        }).promise();
    } catch (err) {
        if (err.code === "ResourceExistsException") {
            await secretsManager.putSecretValue({
                SecretId: secretName,
                SecretString: secretValue,
            }).promise();
        } else {
            throw err;
        }
    }
}

// Verify that the public and private keys are set and valid
async function verifyKeys(tries = 2) {
    if (tries <= 0) {
        return false;
    }
    const publicKey = await getSecret(VAPID_PUBLIC_SECRET);
    const privateKey = await getSecret(VAPID_PRIVATE_SECRET);

    if (!publicKey || !privateKey) {
        await generateKeys();
        return await verifyKeys(tries - 1);
    }

    try {
        webpush.setVapidDetails("mailto:doink@doink.fake", publicKey, privateKey);
        return true;
    } catch (err) {
        return false;
    }
}

async function generateKeys() {
    const keys = webpush.generateVAPIDKeys();
    await storeSecret(VAPID_PUBLIC_SECRET, keys.publicKey);
    await storeSecret(VAPID_PRIVATE_SECRET, keys.privateKey);
}

exports.handler = async (event) => {
    try {
        // if method is POST, generate new keys
        if (event.httpMethod === "POST") {
            await generateKeys();
        }

        // Verify that the keys are set and valid
        if (!await verifyKeys()) {
            await generateKeys();
            if (!await verifyKeys()) {
                throw new Error("Failed to generate valid VAPID keys");
            }
        }

        // Get the public key
        let publicKey = await getSecret(VAPID_PUBLIC_SECRET);

        // Return the public key
        return {
            statusCode: 200,
            headers: {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*", // Adjust for your security needs
            },
            body: JSON.stringify({ vapidPublicKey: publicKey }),
        };
    } catch (err) {
        console.error("Error:", err);
        return {
            statusCode: 500,
            body: JSON.stringify({ error: err.message }),
        };
    }
};
