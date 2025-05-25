###############################################################################
# DynamoDB Table (Store WebSocket Connections)
###############################################################################
resource "aws_dynamodb_table" "chat_connections" {
  name         = "ChatConnections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }
}

###############################################################################
# SQS Queue (Buffer for Messages)
###############################################################################

resource "aws_sqs_queue" "chat_dlq" {
  name = "chat-websocket-queue-dlq"
}

resource "aws_sqs_queue" "chat" {
  name = "chat-websocket-queue"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.chat_dlq.arn
    maxReceiveCount = 1
  })
}

# SNS Topic for DLQ messages
resource "aws_sns_topic" "chat_dlq" {
  name = "chat-websocket-dlq"
}

# Subscribe the DLQ to the SNS topic
resource "aws_sns_topic_subscription" "chat_dlq" {
  topic_arn = aws_sns_topic.chat_dlq.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.chat_dlq.arn
}

# Subscribe admin email to the DLQ
resource "aws_sns_topic_subscription" "chat_dlq_email" {
  topic_arn = aws_sns_topic.chat_dlq.arn
  protocol  = "email"
  endpoint  = var.notify_email[terraform.workspace]
}

###############################################################################
# IAM Role + Policy for Lambdas
###############################################################################
data "aws_iam_policy_document" "chat_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chat" {
  name               = "chat-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.chat_assume_role.json
}

data "aws_iam_policy_document" "chat" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      # DynamoDB read/write
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:Scan",
      "dynamodb:Query",
      "dynamodb:UpdateItem"
    ]
    resources = [aws_dynamodb_table.chat_connections.arn]
  }

  statement {
    actions = [
      # SQS
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl"
    ]
    resources = [aws_sqs_queue.chat.arn, aws_sqs_queue.chat_dlq.arn]
  }

  # Add permission for chat_consumer to push messages to connections
  statement {
    actions = [
      "execute-api:Invoke",
      "execute-api:ManageConnections"
      ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "chat" {
  name   = "chat-lambda-policy"
  role   = aws_iam_role.chat.id
  policy = data.aws_iam_policy_document.chat.json
}

###############################################################################
# 2. Lambdas: Connect, Disconnect, Messages, Consumer, Authorizer
###############################################################################
#
# In real usage, you'd reference your local zip files or use `archive_file`.
# For brevity, we assume you have these zips in the same folder.
#
###############################################################################

data "archive_file" "chat" {
  type = "zip"
  source_dir = "chat"
  output_path = "chat.zip"
}

################### Connect Lambda (WebSocket $connect) #######################
resource "aws_lambda_function" "chat_connect" {
  function_name = "chat-ws-connect"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "connect.handler"
  filename      = "${path.module}/chat.zip"  # Replace with your .zip path
  timeout       = 10  # seconds
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.chat_connections.name
      QUEUE_URL = aws_sqs_queue.chat.id
      DLQ_QUEUE_URL = aws_sqs_queue.chat_dlq.id
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.pool.id
      API_WS_ID = aws_apigatewayv2_api.chat_websocket.id
      API_WS_STAGE = aws_apigatewayv2_stage.chat_websocket.name
    }
  }
}

################### Disconnect Lambda (WebSocket $disconnect) #################
resource "aws_lambda_function" "chat_disconnect" {
  function_name = "chat-ws-disconnect"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "disconnect.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.chat_connections.name
      QUEUE_URL = aws_sqs_queue.chat.id
    }
  }
}

################### Client Config Lambda (WebSocket clientConfig) #############
resource "aws_lambda_function" "chat_client_config" {
  function_name = "chat-client-config"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "clientConfig.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      COGNITO_CLIENT_ID = aws_cognito_user_pool_client.pool.id
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.pool.id
      GOOGLE_CLIENT_ID = var.google_client_id[terraform.workspace]
    }
  }
}

################### Messages Lambda (HTTP: POST /message, /adminMessage) ######
resource "aws_lambda_function" "chat_message" {
  function_name = "chat-message"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "message.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.chat.id
    }
  }
}

################### Consumer Lambda (Consumes SQS, pushes to WebSockets) ######
resource "aws_lambda_function" "chat_consumer" {
  function_name = "chat-consumer"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "consumer.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.chat_connections.name
      API_WS_ID = aws_apigatewayv2_api.chat_websocket.id
      API_WS_STAGE = aws_apigatewayv2_stage.chat_websocket.name
    }
  }
}

######## DLQ Consumer Lambda (Consumes SQS, pushes to Admin WebSockets) ######
resource "aws_lambda_function" "chat_dlq_consumer" {
  function_name = "chat-dlq-consumer"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "dlqConsumer.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.chat_connections.name
      API_WS_ID = aws_apigatewayv2_api.chat_websocket.id
      API_WS_STAGE = aws_apigatewayv2_stage.chat_websocket.name
    }
  }
}

################### Admin Authorizer Lambda (Custom) ##########################
resource "aws_lambda_function" "chat_admin_authorizer" {
  function_name = "chat-admin-authorizer"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "adminAuthorizer.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.pool.id
    }
  }
}
######### List Connections Lambda (HTTP: GET /listConnections) ###############
resource "aws_lambda_function" "chat_list_connections" {
  function_name = "chat-list-connections"
  role          = aws_iam_role.chat.arn
  runtime       = "nodejs18.x"
  handler       = "listConnections.handler"
  filename      = "${path.module}/chat.zip"
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.chat_connections.name
    }
  }
}
###############################################################################
# 3. SQS -> Lambda (Consumer) Event Source Mapping
###############################################################################
resource "aws_lambda_event_source_mapping" "chat_consumer" {
  event_source_arn = aws_sqs_queue.chat.arn
  function_name    = aws_lambda_function.chat_consumer.arn
  enabled          = true
  batch_size       = 10
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_event_source_mapping" "chat_dlq_consumer" {
  event_source_arn = aws_sqs_queue.chat_dlq.arn
  function_name    = aws_lambda_function.chat_dlq_consumer.arn
  enabled          = true
  batch_size       = 10
  function_response_types = ["ReportBatchItemFailures"]
}

###############################################################################
# 4. WebSocket API (for real-time pushes)
###############################################################################
resource "aws_apigatewayv2_api" "chat_websocket" {
  name                       = "chat-ws-api"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# Integrations for connect/disconnect
resource "aws_apigatewayv2_integration" "chat_connect" {
  api_id           = aws_apigatewayv2_api.chat_websocket.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.chat_connect.arn
}

resource "aws_apigatewayv2_integration" "chat_disconnect" {
  api_id           = aws_apigatewayv2_api.chat_websocket.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.chat_disconnect.arn
}

# Routes
resource "aws_apigatewayv2_route" "chat_connect" {
  api_id    = aws_apigatewayv2_api.chat_websocket.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.chat_connect.id}"
}

resource "aws_apigatewayv2_route" "chat_disconnect" {
  api_id    = aws_apigatewayv2_api.chat_websocket.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.chat_disconnect.id}"
}

# WebSocket Stage
resource "aws_apigatewayv2_stage" "chat_websocket" {
  api_id      = aws_apigatewayv2_api.chat_websocket.id
  name        = "ws"
  auto_deploy = true
}

# Permissions so API Gateway can invoke the connect/disconnect lambdas
resource "aws_lambda_permission" "chat_connect" {
  statement_id  = "ConnectPermission"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_connect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat_websocket.execution_arn}/*"
}

resource "aws_lambda_permission" "chat_disconnect" {
  statement_id  = "DisconnectPermission"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_disconnect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat_websocket.execution_arn}/*"
}

output "websocket_endpoint" {
  description = "WebSocket URL"
  value       = "${aws_apigatewayv2_api.chat_websocket.api_endpoint}/${aws_apigatewayv2_stage.chat_websocket.name}"
}

###############################################################################
# 5. HTTP API (for the unified /message, /adminMessage)
###############################################################################
resource "aws_apigatewayv2_api" "chat_http" {
  name          = "chat-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = concat([
      "https://${var.domain_name[terraform.workspace]}",
      "https://www.${var.domain_name[terraform.workspace]}"
    ], terraform.workspace == "prod" ? [
      "https://alijamaluddin.com",
      "https://www.alijamaluddin.com"
    ] : [])
    allow_methods = ["GET", "POST"] # Include all methods you use
    allow_headers = ["*"]           # Or just "Content-Type", "Authorization", etc.
    expose_headers = []
    max_age = 86400
  }
}

# Log group for HTTP API
resource "aws_cloudwatch_log_group" "chat_http" {
  name              = "/aws/apigateway/chat-http"
  retention_in_days = 7
}

# Single integration for both routes (POST /message, POST /adminMessage)
resource "aws_apigatewayv2_integration" "chat_message" {
  api_id           = aws_apigatewayv2_api.chat_http.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.chat_message.arn
}

# Integration for clientConfig (GET /clientConfig)
resource "aws_apigatewayv2_integration" "chat_client_config" {
  api_id           = aws_apigatewayv2_api.chat_http.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.chat_client_config.arn
}

# Integration for listConnections (GET /listConnections)
resource "aws_apigatewayv2_integration" "chat_list_connections" {
  api_id           = aws_apigatewayv2_api.chat_http.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.chat_list_connections.arn
}

# Public route: POST /message
resource "aws_apigatewayv2_route" "chat_post_message" {
  api_id    = aws_apigatewayv2_api.chat_http.id
  route_key = "POST /message"
  target    = "integrations/${aws_apigatewayv2_integration.chat_message.id}"
}

# Public route: GET /clientConfig
resource "aws_apigatewayv2_route" "chat_get_client_config" {
  api_id    = aws_apigatewayv2_api.chat_http.id
  route_key = "GET /clientConfig"
  target    = "integrations/${aws_apigatewayv2_integration.chat_client_config.id}"
}

# Admin route: POST /adminMessage (protected by custom authorizer)
resource "aws_apigatewayv2_route" "chat_post_admin_message" {
  api_id            = aws_apigatewayv2_api.chat_http.id
  route_key         = "POST /adminMessage"
  target            = "integrations/${aws_apigatewayv2_integration.chat_message.id}"
  authorizer_id     = aws_apigatewayv2_authorizer.chat_admin_auth.id
  authorization_type = "CUSTOM"
}

# Custom Lambda Authorizer for /adminMessage
resource "aws_apigatewayv2_authorizer" "chat_admin_auth" {
  api_id           = aws_apigatewayv2_api.chat_http.id
  authorizer_type  = "REQUEST"
  # The crucial part: must follow the "arn:aws:apigateway:REGION:lambda:path/2015-03-31/functions/<LambdaARN>/invocations" format
  authorizer_uri  = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/${aws_lambda_function.chat_admin_authorizer.arn}/invocations"
  name             = "AdminAuthorizer"
  identity_sources  = ["$request.header.Authorization"]
  authorizer_payload_format_version = "2.0"

  # Disable caching by setting the TTL to 0
  authorizer_result_ttl_in_seconds       = 0
}

# Admin route: GET /listConnections
resource "aws_apigatewayv2_route" "chat_get_list_connections" {
  api_id    = aws_apigatewayv2_api.chat_http.id
  route_key = "GET /listConnections"
  target    = "integrations/${aws_apigatewayv2_integration.chat_list_connections.id}"
  authorizer_id     = aws_apigatewayv2_authorizer.chat_admin_auth.id
  authorization_type = "CUSTOM"
}

# Stage
resource "aws_apigatewayv2_stage" "chat_http" {
  api_id      = aws_apigatewayv2_api.chat_http.id
  name        = "v2"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.chat_http.arn
    format          = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      requestTime = "$context.requestTime"
      httpMethod  = "$context.httpMethod"
      routeKey    = "$context.routeKey"
      status      = "$context.status"
      protocol    = "$context.protocol"
      responseLength = "$context.responseLength"
      authorizerError = "$context.authorizer.error"
      authorizerPrincipalId = "$context.authorizer.principalId"
      errorMessage = "$context.error.message"
      integrationError = "$context.integration.error"
      integrationStatus = "$context.integration.status"



    })
  }
}

# Permissions for the messages and authorizer lambdas
resource "aws_lambda_permission" "chat_message" {
  statement_id  = "AllowHttpInvokeMessages"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_message.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat_http.execution_arn}/*"
}

resource "aws_lambda_permission" "chat_client_config" {
  statement_id  = "AllowHttpInvokeClientConfig"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_client_config.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat_http.execution_arn}/*"
}

resource "aws_lambda_permission" "chat_list_connections" {
  statement_id  = "AllowHttpInvokeListConnections"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_list_connections.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat_http.execution_arn}/*"
}

resource "aws_lambda_permission" "chat_admin_authorizer" {
  statement_id  = "AllowHttpInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_admin_authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat_http.execution_arn}/*"
}

output "http_api_endpoint" {
  description = "Base URL for the HTTP API"
  value       = aws_apigatewayv2_stage.chat_http.invoke_url
}


resource "aws_apigatewayv2_domain_name" "chat_api_ws" {
  domain_name = "api-ws.${var.domain_name[terraform.workspace]}"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate.api_cert.arn
    endpoint_type    = "REGIONAL"
    security_policy  = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_domain_name" "chat_api" {
  domain_name = "api.${var.domain_name[terraform.workspace]}"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate.api_cert.arn
    endpoint_type    = "REGIONAL"
    security_policy  = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "chat_websocket_mapping" {
  api_id      = aws_apigatewayv2_api.chat_websocket.id
  domain_name = aws_apigatewayv2_domain_name.chat_api_ws.domain_name
  stage       = aws_apigatewayv2_stage.chat_websocket.name
  api_mapping_key = ""
}

resource "aws_apigatewayv2_api_mapping" "chat_http_mapping" {
  api_id      = aws_apigatewayv2_api.chat_http.id
  domain_name = aws_apigatewayv2_domain_name.chat_api.domain_name
  stage       = aws_apigatewayv2_stage.chat_http.name
  api_mapping_key = ""
}

# Production-only domain names for alijamaluddin.com
resource "aws_apigatewayv2_domain_name" "chat_api_ws_alijamaluddin" {
  count = terraform.workspace == "prod" ? 1 : 0

  domain_name = "api-ws.alijamaluddin.com"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate.api_cert.arn
    endpoint_type    = "REGIONAL"
    security_policy  = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_domain_name" "chat_api_alijamaluddin" {
  count = terraform.workspace == "prod" ? 1 : 0

  domain_name = "api.alijamaluddin.com"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate.api_cert.arn
    endpoint_type    = "REGIONAL"
    security_policy  = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "chat_websocket_mapping_alijamaluddin" {
  count = terraform.workspace == "prod" ? 1 : 0

  api_id      = aws_apigatewayv2_api.chat_websocket.id
  domain_name = aws_apigatewayv2_domain_name.chat_api_ws_alijamaluddin[0].domain_name
  stage       = aws_apigatewayv2_stage.chat_websocket.name
  api_mapping_key = ""
}

resource "aws_apigatewayv2_api_mapping" "chat_http_mapping_alijamaluddin" {
  count = terraform.workspace == "prod" ? 1 : 0

  api_id      = aws_apigatewayv2_api.chat_http.id
  domain_name = aws_apigatewayv2_domain_name.chat_api_alijamaluddin[0].domain_name
  stage       = aws_apigatewayv2_stage.chat_http.name
  api_mapping_key = ""
}
