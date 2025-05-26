# Tucker McLean Website Backend Infrastructure

This repository contains the infrastructure as code (IaC) and backend services for tuckermclean.com, implemented using Terraform and AWS services.

## Project Structure

```
.
├── .github/
│   └── workflows/
│       └── terraform-apply.yml    # CI/CD pipeline for Terraform deployments
├── chat/                          # Chat service implementation
│   ├── adminAuthorizer.js        # Admin authorization Lambda
│   ├── clientConfig.js           # Client configuration
│   ├── cognitoTokenVerifier.js   # Cognito token verification
│   ├── connect.js               # WebSocket connection handler
│   ├── consumer.js              # Message consumer
│   ├── disconnect.js            # WebSocket disconnection handler
│   ├── dlqConsumer.js           # Dead Letter Queue consumer
│   ├── listConnections.js       # Connection listing utility
│   ├── message.js               # Message handling
│   ├── package.json            # Node.js dependencies
│   └── package-lock.json       # Locked Node.js dependencies
├── main.tf                      # Core infrastructure configuration
├── variables.tf.example         # Example variables file
├── outputs.tf                   # Terraform outputs
├── s3.tf                        # S3 bucket configurations
├── route53.tf                   # DNS configurations
├── cognito.tf                   # AWS Cognito setup
├── chat.tf                      # Chat service infrastructure
└── iam.tf                       # IAM roles and policies
```

## Prerequisites

- AWS CLI configured with appropriate credentials
  - After logging in with `aws configure`, set your AWS_PROFILE:
    ```bash
    export AWS_PROFILE=your-profile-name
    ```
- Terraform >= 1.10.4
- Node.js (for local development of Lambda functions)
- GitHub account with access to this repository

## Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/tuckermclean.com_backend.git
   cd tuckermclean.com_backend
   ```

2. Create a `variables.tf` file based on `variables.tf.example`:
   ```bash
   cp variables.tf.example variables.tf
   ```

3. Edit `variables.tf` with your specific values.

4. Initialize Terraform:
   ```bash
   terraform init
   ```

## Infrastructure Components

- **S3**: Static website hosting and file storage
- **Route53**: DNS management
- **Cognito**: User authentication and management
- **Lambda**: Serverless functions for chat and other services
- **IAM**: Security roles and policies
- **ACM**: SSL/TLS certificates

## Deployment

### Automated Deployment

The infrastructure is automatically deployed via GitHub Actions when changes are pushed to the `master` branch. The workflow:
1. Initializes Terraform
2. Validates the configuration
3. Creates and applies a plan
4. Reports success or failure

### Manual Deployment

To deploy manually:

1. Select the appropriate workspace:
   ```bash
   terraform workspace select <workspace-name>
   ```

2. Plan the changes:
   ```bash
   terraform plan
   ```

3. Apply the changes:
   ```bash
   terraform apply
   ```

## Development

### Chat Service

The chat service is implemented as a collection of Lambda functions. To work on it locally:

1. Navigate to the chat directory:
   ```bash
   cd chat
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Make your changes and test locally.

4. Create deployment packages:
   ```bash
   npm run build
   ```

## Security

- AWS credentials are managed through GitHub Secrets
- Terraform state is stored in an S3 bucket with DynamoDB locking
- IAM roles follow the principle of least privilege
- Sensitive variables are not committed to the repository

## Contributing

1. Create a new branch for your changes
2. Make your changes
3. Test thoroughly
4. Submit a pull request

## License

All code © 2025 Tucker McLean — licensed under the [MIT License](/LICENSE)

## Contact

Direct all love notes and hate mail to Tucker McLean; me@tuckermclean.com