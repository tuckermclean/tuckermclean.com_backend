# tuckermclean.com Backend Infrastructure

Terraform-managed AWS infrastructure powering [tuckermclean.com](https://tuckermclean.com) (and its alias [alijamaluddin.com](https://alijamaluddin.com) in production). This repo provisions everything from DNS and CDN to a real-time WebSocket chat system, all deployed automatically via GitHub Actions on push to `master`.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [AWS Services Used](#aws-services-used)
- [DNS & Domain Layout](#dns--domain-layout)
- [Chat Service Deep Dive](#chat-service-deep-dive)
- [Dev Environment Setup](#dev-environment-setup)
- [Configuration Reference](#configuration-reference)
- [Terraform Workspaces](#terraform-workspaces)
- [Deployment](#deployment)
- [GitHub Actions CI/CD](#github-actions-cicd)
- [GitHub Secrets Reference](#github-secrets-reference)
- [Manual Operations](#manual-operations)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Architecture Overview

```
                                 ┌─────────────────┐
                                 │   Route 53       │
                                 │  (DNS zones)     │
                                 └────────┬─────────┘
                                          │
              ┌───────────────────────────┬┴──────────────────────────┐
              │                           │                          │
     ┌────────▼─────────┐    ┌───────────▼──────────┐   ┌──────────▼──────────┐
     │   CloudFront CDN  │    │  API Gateway (HTTP)  │   │ API Gateway (WebSocket)│
     │  (static site)    │    │  api.<domain>/v2     │   │ api-ws.<domain>/ws     │
     └────────┬──────────┘    └───────────┬──────────┘   └──────────┬──────────┘
              │                           │                          │
     ┌────────▼──────────┐    ┌───────────▼──────────┐   ┌──────────▼──────────┐
     │   S3 Bucket        │    │  Lambda Functions    │   │  Lambda Functions    │
     │  (website files)   │    │  (message, config,   │   │  (connect,           │
     └────────────────────┘    │   authorizer, list)  │   │   disconnect)        │
                               └───────────┬──────────┘   └──────────────────────┘
                                           │
                                  ┌────────▼─────────┐
                                  │   SQS Queue       │
                                  │  (message buffer) │
                                  └────────┬──────────┘
                                           │
                                  ┌────────▼─────────┐
                                  │  Consumer Lambda   │──────► WebSocket push
                                  └────────┬──────────┘        to connections
                                           │ (on failure)
                                  ┌────────▼─────────┐
                                  │  Dead Letter Queue │
                                  │  + DLQ Consumer    │
                                  └────────┬──────────┘
                                           │
                                  ┌────────▼─────────┐
                                  │  SNS Topic         │──► Email notification
                                  └──────────────────┘

     ┌────────────────────┐
     │  Cognito User Pool  │   Google OAuth 2.0 IdP
     │  + admin group      │   Hosted UI at auth.<domain>
     └────────────────────┘

     ┌────────────────────┐
     │  DynamoDB Table     │   ChatConnections
     │  (connectionId PK)  │   Tracks active WebSocket sessions
     └────────────────────┘
```

**In plain English:** A static website is served from S3 via CloudFront. The site includes a live chat feature where visitors connect over WebSocket, send messages via an HTTP API, and those messages flow through SQS to a consumer Lambda that pushes them to admin WebSocket connections in real time. If no admin is online, messages land in a Dead Letter Queue and get retried when an admin connects. Cognito handles authentication with Google as the identity provider.

---

## Project Structure

```
.
├── .github/
│   └── workflows/
│       └── terraform-apply.yml     # CI/CD: auto-deploys on push to master
├── chat/                           # Lambda function source code (Node.js)
│   ├── adminAuthorizer.js          # Custom Lambda authorizer — checks Cognito admin group
│   ├── clientConfig.js             # Returns Cognito/Google client IDs to the frontend
│   ├── cognitoTokenVerifier.js     # Shared JWT verification against Cognito JWKS
│   ├── connect.js                  # WebSocket $connect handler — registers connection in DynamoDB
│   ├── consumer.js                 # SQS consumer — routes messages to WebSocket connections
│   ├── disconnect.js               # WebSocket $disconnect handler — removes connection from DynamoDB
│   ├── dlqConsumer.js              # DLQ consumer — retries guest messages when admin reconnects
│   ├── listConnections.js          # Admin endpoint — lists all active WebSocket connections
│   ├── message.js                  # HTTP handler for POST /message and POST /adminMessage
│   ├── package.json                # Node.js dependencies (aws-sdk, jsonwebtoken, jwk-to-pem)
│   └── package-lock.json           # Locked dependency versions
├── main.tf                         # Terraform backend config, providers, ACM certificates
├── variables.tf.example            # Template for your variables.tf (gitignored)
├── outputs.tf                      # Terraform outputs (nameservers, API URLs, client IDs)
├── s3.tf                           # S3 bucket, CloudFront CDN, URL rewrite function
├── route53.tf                      # DNS zones and records for all domains
├── cognito.tf                      # Cognito user pool, Google IdP, user pool client
├── chat.tf                         # Chat infrastructure: DynamoDB, SQS, Lambdas, API Gateway
├── iam.tf                          # IAM users/policies for CI/CD (S3 deploy, Terraform apply)
├── .gitignore                      # Ignores .terraform/, state files, variables.tf, zips, node_modules
├── .gitattributes                  # Forces LF line endings
├── LICENSE                         # MIT License
└── README.md                       # This file
```

---

## AWS Services Used

| Service | Purpose |
|---|---|
| **S3** | Hosts the static website files (HTML/CSS/JS). Bucket named after the domain. Public read access. |
| **CloudFront** | CDN in front of S3. HTTPS only (TLS 1.2+). Rewrites bare directory paths to `index.html` via a CloudFront Function. Custom 404 → `error.html`. |
| **Route 53** | DNS zones for `tuckermclean.com` and (prod only) `alijamaluddin.com`. A-records for root, www, auth, api, api-ws. MX/DKIM/SPF records for Fastmail. |
| **ACM** | Two certificates: one in `us-east-1` for CloudFront/Cognito (root, www, auth + alias domains), one in `us-west-2` for API Gateway (api, api-ws + alias domains). DNS-validated. |
| **Cognito** | User pool with Google as an identity provider. Hosted UI at `auth.<domain>`. Admin group controls chat admin access. OAuth 2.0 authorization code flow. |
| **API Gateway v2 (HTTP)** | REST-style HTTP API at `api.<domain>/v2`. Routes: `POST /message` (public), `POST /adminMessage` (admin-authorized), `GET /clientConfig` (public), `GET /listConnections` (admin-authorized). CORS configured for the website origins. |
| **API Gateway v2 (WebSocket)** | WebSocket API at `api-ws.<domain>/ws`. Routes: `$connect`, `$disconnect`. Route selection expression: `$request.body.action`. |
| **Lambda** | 8 functions, all Node.js 18.x, packaged from the `chat/` directory as a single zip. See [Chat Service Deep Dive](#chat-service-deep-dive). |
| **DynamoDB** | `ChatConnections` table. Partition key: `connectionId` (String). Stores `isAdmin` boolean. Pay-per-request billing. |
| **SQS** | Main queue (`chat-websocket-queue`) buffers all chat messages. Dead Letter Queue (`chat-websocket-queue-dlq`) catches failures after 1 retry. |
| **SNS** | Topic `chat-websocket-dlq` — DLQ messages are published here and emailed to the configured notification address. |
| **IAM** | Two CI/CD users: `s3-update-user` (can push to the website S3 bucket — used by the frontend repo) and `terraform-update-user` (full admin — used by this repo's GitHub Action). Lambda execution role with permissions for CloudWatch Logs, DynamoDB, SQS, and API Gateway connection management. |

---

## DNS & Domain Layout

All domains resolve through Route 53. In production, `alijamaluddin.com` is an alias that points to the same CloudFront distribution and API endpoints as `tuckermclean.com`.

| Subdomain | Points To | Notes |
|---|---|---|
| `<domain>` | CloudFront CDN | Static site |
| `www.<domain>` | CloudFront CDN | Same distribution |
| `auth.<domain>` | Cognito Hosted UI | Custom domain on the user pool |
| `api.<domain>` | HTTP API Gateway | REST endpoints (stage: `v2`) |
| `api-ws.<domain>` | WebSocket API Gateway | Real-time connections (stage: `ws`) |

**Email (Fastmail):** MX records on root and wildcard point to `in1-smtp.messagingengine.com` / `in2-smtp.messagingengine.com`. DKIM via three CNAME records (`fm1`, `fm2`, `fm3`). SPF via TXT record.

---

## Chat Service Deep Dive

The chat system enables real-time communication between website visitors (guests) and the site admin. Here's how each piece works:

### Message Flow

1. **Guest connects** → WebSocket `$connect` → `connect.js` registers the `connectionId` in DynamoDB, queues a `newConnection` event (for admins) and a `welcome` message (for the guest) to SQS.
2. **Guest sends a message** → HTTP `POST /message` → `message.js` enqueues a `guestMessage` to SQS.
3. **SQS triggers `consumer.js`** → reads the message type:
   - `guestMessage`, `newConnection`, `endConnection` → pushed to all admin WebSocket connections.
   - `welcome`, `adminMessage` → pushed to the specific visitor's WebSocket connection.
   - If no admin is connected, the guest gets a `noAdmins` WebSocket message and the SQS message fails intentionally → moves to DLQ after 1 retry.
4. **Admin sends a reply** → HTTP `POST /adminMessage` (protected by `adminAuthorizer.js`) → `message.js` enqueues an `adminMessage` to SQS → consumer delivers it to the visitor.
5. **DLQ Consumer** → When triggered (admin connects or messages accumulate), `dlqConsumer.js` reads from the DLQ and re-attempts delivery of `guestMessage` types to admins.
6. **Guest disconnects** → WebSocket `$disconnect` → `disconnect.js` removes the connection from DynamoDB and queues an `endConnection` event.

### Lambda Functions

| Function | Trigger | Handler | Purpose |
|---|---|---|---|
| `chat-ws-connect` | WebSocket `$connect` | `connect.handler` | Registers connection. If `accessToken` query param is present, verifies Cognito JWT and checks for admin group membership. |
| `chat-ws-disconnect` | WebSocket `$disconnect` | `disconnect.handler` | Removes connection from DynamoDB, notifies admins. |
| `chat-message` | HTTP `POST /message`, `POST /adminMessage` | `message.handler` | Parses JSON body, enqueues to SQS as `guestMessage` or `adminMessage`. |
| `chat-consumer` | SQS `chat-websocket-queue` | `consumer.handler` | Routes messages to WebSocket connections. Batch size 10, reports partial failures. |
| `chat-dlq-consumer` | SQS `chat-websocket-queue-dlq` | `dlqConsumer.handler` | Retries `guestMessage` delivery to admins. Drops other message types. |
| `chat-admin-authorizer` | API Gateway authorizer | `adminAuthorizer.handler` | Validates `Authorization: Bearer <token>` header. Checks Cognito JWT for `admin` group. Returns IAM policy. |
| `chat-client-config` | HTTP `GET /clientConfig` | `clientConfig.handler` | Returns Cognito client ID, user pool ID, and Google client ID as JSON. |
| `chat-list-connections` | HTTP `GET /listConnections` | `listConnections.handler` | Scans DynamoDB, returns all active connections with their admin status. Admin-only. |

### Message Types (SQS payloads)

| Type | Direction | Fields |
|---|---|---|
| `newConnection` | System → Admins | `connectionId`, `timestamp` |
| `endConnection` | System → Admins | `connectionId`, `timestamp` |
| `welcome` | System → Guest | `connectionId`, `isAdmin` |
| `guestMessage` | Guest → Admins | `connectionId`, `message`, `name`, `email`, `phone`, `timestamp` |
| `adminMessage` | Admin → Guest | `targetConnectionId`, `message`, `name`, `email`, `phone`, `timestamp` |
| `noAdmins` | System → Guest | (all fields from original message, type overwritten) |
| `visitorNotFound` | System → Admins | (all fields from original message, type overwritten) |

### Authentication

- **Cognito User Pool** with Google as the sole federated identity provider (direct Cognito sign-in is also enabled).
- OAuth 2.0 authorization code flow via the Cognito Hosted UI at `auth.<domain>`.
- Callback URL: `https://<domain>/callback.html`; Logout URL: `https://<domain>/logout.html`.
- Admin access is granted by membership in the Cognito `admin` group.
- The `adminAuthorizer` Lambda verifies JWTs by fetching the JWKS from Cognito's well-known endpoint, finding the matching key by `kid`, converting to PEM, and verifying with `jsonwebtoken`.
- WebSocket connections can optionally pass an `accessToken` query parameter on connect; if present and valid with admin group membership, the connection is flagged as admin in DynamoDB.

---

## Dev Environment Setup

Follow these steps to set up a fresh development machine.

### 1. Prerequisites

Install the following tools:

| Tool | Minimum Version | Installation |
|---|---|---|
| **Terraform** | 1.10.4 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/install) or `brew install terraform` / `pacman -S terraform` |
| **AWS CLI** | v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) or `brew install awscli` / `pacman -S aws-cli-v2` |
| **Node.js** | 18.x | [nodejs.org](https://nodejs.org/) or via `nvm` (recommended for matching the Lambda runtime) |
| **Git** | any recent | You probably have this already |

### 2. AWS Credentials

You need an AWS IAM user (or role) with sufficient permissions to manage all the services in this repo. For local development, the easiest path:

```bash
aws configure
# Enter your Access Key ID, Secret Access Key, region (us-west-2), output format (json)

# Then set the profile for this session:
export AWS_PROFILE=your-profile-name
```

The Terraform backend expects access to the S3 bucket `tuckermclean.com-terraform-state` and the DynamoDB table `TerraformStateLock` in `us-west-2`. Your IAM user must have permissions for these.

### 3. Clone and Configure

```bash
git clone git@github.com:tuckermclean/tuckermclean.com_backend.git
cd tuckermclean.com_backend
```

Create your variables file from the template:

```bash
cp variables.tf.example variables.tf
```

Edit `variables.tf` and fill in your actual values. This file is gitignored and contains secrets. The variables are **workspace-keyed maps** — you need values for `default`, `dev`, and `prod` keys in each variable. See [Configuration Reference](#configuration-reference).

### 4. Initialize Terraform

```bash
terraform init
```

This downloads provider plugins and configures the S3 backend. You should see:

```
Terraform has been successfully initialized!
```

### 5. Select a Workspace

```bash
# List available workspaces
terraform workspace list

# Use the dev workspace for development
terraform workspace select dev

# Or create it if it doesn't exist
terraform workspace new dev
```

### 6. Install Chat Dependencies (for local Lambda development)

```bash
cd chat
npm install
cd ..
```

The Lambda zip is built by Terraform's `archive_file` data source at plan/apply time, so you don't need a separate build step. But `npm install` is needed so the `node_modules` are present when Terraform zips the directory.

### 7. Verify Everything Works

```bash
terraform plan
```

This should produce a plan showing what would be created/changed. Review it — don't apply against prod accidentally.

---

## Configuration Reference

All variables are defined in `variables.tf` (gitignored, created from `variables.tf.example`). Every variable is a **map keyed by Terraform workspace name** (`default`, `dev`, `prod`):

| Variable | Type | Description |
|---|---|---|
| `google_client_id` | `map(string)` | Google OAuth 2.0 client ID (from Google Cloud Console). |
| `google_client_secret` | `map(string)` | Google OAuth 2.0 client secret. **Sensitive.** |
| `github_token` | `map(string)` | GitHub personal access token. **Sensitive.** Used for repository access. |
| `domain_name` | `map(string)` | The apex domain (e.g., `tuckermclean.com` for prod, a test domain for dev). |
| `sms_phone_number` | `map(string)` | Phone number for SMS notifications (E.164 format: `+1234567890`). |
| `notify_email` | `map(string)` | Email address for SNS notifications (DLQ alerts). |
| `index_name` | `string` | OpenSearch index name. Default: `github-repos`. |
| `github_repos` | `map(list(string))` | List of GitHub repos to process (for chatbot feature). |

---

## Terraform Workspaces

This project uses [Terraform workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces) to manage separate environments from a single codebase. The workspace name is used as a key into all variable maps.

| Workspace | Purpose | Domain (typical) |
|---|---|---|
| `dev` | Development/testing | A test domain you control |
| `prod` | Production | `tuckermclean.com` |

Production-only resources (gated by `terraform.workspace == "prod"`):
- `alijamaluddin.com` Route 53 zone and all its DNS records
- `alijamaluddin.com` aliases on CloudFront, ACM certs, API Gateway domain names, and Cognito callback/logout URLs

---

## Deployment

### Automated (GitHub Actions)

Every push to `master` triggers the **Terraform Apply** workflow (`.github/workflows/terraform-apply.yml`). It can also be triggered manually via `workflow_dispatch`.

The workflow:
1. Checks out the code
2. Installs Terraform 1.10.4
3. Configures AWS credentials from GitHub Secrets
4. Writes `variables.tf` from the `TERRAFORM_VARS` secret
5. Runs `terraform init`
6. Runs `terraform validate`
7. Runs `terraform plan -out=tfplan`
8. Runs `terraform apply -auto-approve tfplan`

The workspace is set via the `TERRAFORM_WORKSPACE` secret (exported as `TF_WORKSPACE` env var, which Terraform reads automatically).

### Manual

```bash
# Make sure you're in the right workspace
terraform workspace select dev

# Preview changes
terraform plan

# Apply
terraform apply
```

---

## GitHub Secrets Reference

These secrets must be configured in the GitHub repository settings for CI/CD to work:

| Secret | Description |
|---|---|
| `TERRAFORM_AWS_ACCESS_KEY_ID` | Access key for the `terraform-update-user` IAM user |
| `TERRAFORM_AWS_SECRET_ACCESS_KEY` | Secret key for the `terraform-update-user` IAM user |
| `AWS_REGION` | AWS region (e.g., `us-west-2`) |
| `TERRAFORM_WORKSPACE` | Which Terraform workspace to use (e.g., `prod`) |
| `TERRAFORM_VARS` | The entire contents of `variables.tf`, stored as a secret and written to disk at deploy time |

The IAM access keys are generated by Terraform itself (see `iam.tf` outputs). After first bootstrapping the infrastructure manually, capture these outputs and store them as GitHub Secrets:

```bash
terraform output s3_access_key_id           # For the frontend repo's CI/CD
terraform output s3_secret_access_key       # For the frontend repo's CI/CD
terraform output terraform_access_key_id    # For this repo's CI/CD
terraform output terraform_secret_access_key # For this repo's CI/CD
```

---

## Manual Operations

### Viewing Terraform State

```bash
terraform state list           # List all managed resources
terraform state show <resource> # Show details of a specific resource
terraform output               # Show all outputs (nameservers, API URLs, etc.)
```

### Updating Nameservers

After initial deployment, you need to point your domain registrar's nameservers to the ones Terraform outputs:

```bash
terraform output nameservers
```

Set these at your registrar for both `tuckermclean.com` and `alijamaluddin.com`.

### Adding a User to the Admin Group

Use the AWS CLI or Console to add a Cognito user to the `admin` group:

```bash
aws cognito-idp admin-add-user-to-group \
  --user-pool-id <pool-id> \
  --username <username> \
  --group-name admin
```

### Checking Lambda Logs

```bash
# Recent logs for a specific function
aws logs tail /aws/lambda/chat-ws-connect --follow

# Or for the HTTP API access logs
aws logs tail /aws/apigateway/chat-http --follow
```

### Inspecting the Connections Table

```bash
aws dynamodb scan --table-name ChatConnections
```

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---|---|---|
| `terraform init` fails with S3 backend error | Missing AWS credentials or wrong region | Run `aws configure` and ensure you can access `tuckermclean.com-terraform-state` in `us-west-2` |
| Certificate validation stuck in `PENDING` | DNS records not created yet or propagation delay | Check Route 53 for the CNAME validation records; wait up to 30 minutes |
| Chat WebSocket connections fail | Wrong API Gateway endpoint or CORS issue | Check `terraform output websocket_endpoint`; verify the frontend uses `wss://api-ws.<domain>/ws` |
| Admin messages going to DLQ | No admin connected when guest sends message | This is by design — messages retry when admin connects. Check DLQ consumer logs if messages never arrive. |
| `POST /adminMessage` returns 403 | Invalid or expired access token, or user not in admin group | Verify the token with `jwt.io`; check Cognito group membership |
| Lambda zip not updating | Terraform doesn't detect source changes | Run `terraform taint data.archive_file.chat` or delete `chat.zip` and re-plan |
| Alijamaluddin resources not created | Wrong workspace | Alias domain resources only exist in `prod` workspace |

---

## License

All code &copy; 2025 Tucker McLean &mdash; licensed under the [MIT License](LICENSE).

## Contact

Direct all love notes and hate mail to Tucker McLean: me@tuckermclean.com
