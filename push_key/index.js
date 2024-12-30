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

exports.handler = async (event) => {
    try {
        // Check if public key already exists
        let publicKey = await getSecret(VAPID_PUBLIC_SECRET);

        if (!publicKey) {
            // Generate new VAPID keys if not found
            const keys = webpush.generateVAPIDKeys();
            publicKey = keys.publicKey;
            const privateKey = keys.privateKey;

            // Store the keys in Secrets Manager
            await storeSecret(VAPID_PUBLIC_SECRET, publicKey);
            await storeSecret(VAPID_PRIVATE_SECRET, privateKey);
        }

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
