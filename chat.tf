#####################################################################
# 1. Provider & basic setup
#####################################################################
#terraform {
#  required_version = ">= 1.0.0"
#  required_providers {
#    aws = {
#      source  = "hashicorp/aws"
#      version = "~> 5.0"  # or your preferred version
#    }
#  }
#}

#provider "aws" {
#  region = "us-east-1"
#}

#####################################################################
# 2. DynamoDB table for storing connections
#####################################################################
resource "aws_dynamodb_table" "connections_table" {
  name         = "ChatConnections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }
}

#####################################################################
# 3. IAM Role & Policy for Lambda
#####################################################################
resource "aws_iam_role" "lambda_exec_role" {
  name               = "LambdaExecRole"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "LambdaDynamoDBPolicy"
  description = "Policy for Lambdas to access DynamoDB and manage connections"
  policy      = data.aws_iam_policy_document.lambda_policy_doc.json
}

data "aws_iam_policy_document" "lambda_policy_doc" {
  statement {
    actions = [
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
      "dynamodb:Scan"
    ]
    resources = [aws_dynamodb_table.connections_table.arn]
  }

  statement {
    actions = [
      "execute-api:ManageConnections"
    ]
    # ManageConnections allows the Lambda to post messages to connections on the API
    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "cognito-idp:AdminListGroupsForUser",
    ]
    resources = [
      aws_cognito_user_pool.pool.arn,
    ]
  }

}

resource "aws_iam_role_policy_attachment" "lambda_exec_role_attachment" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

#####################################################################
# 4. Lambda functions (Connect, Disconnect, SendMessage)
#####################################################################
# -- We'll create a single Lambda code zip that exports 3 handlers.
# -- Or you could create separate Lambdas from separate zips.

# Package archive file for push key Lambda
data "archive_file" "chat" {
  type = "zip"
  source_dir = "chat"
  output_path = "chat.zip"
}

resource "aws_lambda_function" "ws_handler_lambda" {
  function_name = "WebSocketChatHandler"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  publish       = true
  timeout       = 10

  # The code will be packaged locally. You can also point to S3, etc.
  filename         = "chat.zip" 
  source_code_hash = data.archive_file.chat.output_base64sha256
  # The above references a zip file that you presumably have
  # in your Terraform folder. We'll talk about building that next.
  environment {
    variables = {
      USER_POOL_ID = aws_cognito_user_pool.pool.id,
      CLIENT_ID = aws_cognito_user_pool_client.pool.id,
    }
  }
}

#####################################################################
# 5. API Gateway WebSocket (no auth)
#####################################################################
resource "aws_apigatewayv2_api" "guest_ws_api" {
  name                = "GuestWebSocketAPI"
  protocol_type       = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# Integration for all routes
resource "aws_apigatewayv2_integration" "guest_ws_integration" {
  api_id                = aws_apigatewayv2_api.guest_ws_api.id
  integration_type      = "AWS_PROXY"
  integration_uri       = aws_lambda_function.ws_handler_lambda.arn
  integration_method    = "POST"
}

# Routes
resource "aws_apigatewayv2_route" "guest_connect" {
  api_id    = aws_apigatewayv2_api.guest_ws_api.id
  route_key = "$connect"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.guest_ws_integration.id}"
}

resource "aws_apigatewayv2_route" "guest_disconnect" {
  api_id    = aws_apigatewayv2_api.guest_ws_api.id
  route_key = "$disconnect"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.guest_ws_integration.id}"
}

resource "aws_apigatewayv2_route" "guest_sendmessage" {
  api_id    = aws_apigatewayv2_api.guest_ws_api.id
  route_key = "sendMessage"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.guest_ws_integration.id}"
}

resource "aws_apigatewayv2_route_response" "guest_sendmessage" {
  api_id    = aws_apigatewayv2_api.guest_ws_api.id
  route_id  = aws_apigatewayv2_route.guest_sendmessage.id
  route_response_key = "$default"
}

resource "aws_apigatewayv2_route" "guest_authenticate" {
  api_id    = aws_apigatewayv2_api.guest_ws_api.id
  route_key = "authenticate"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.guest_ws_integration.id}"
}

resource "aws_apigatewayv2_route_response" "guest_authenticate" {
  api_id    = aws_apigatewayv2_api.guest_ws_api.id
  route_id  = aws_apigatewayv2_route.guest_authenticate.id
  route_response_key = "$default"
}

# Stage
resource "aws_apigatewayv2_stage" "guest_stage" {
  api_id      = aws_apigatewayv2_api.guest_ws_api.id
  name        = "prod"
  auto_deploy = true
}

# Permissions
resource "aws_lambda_permission" "guest_ws_permission" {
  statement_id  = "AllowWebSocketInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ws_handler_lambda.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.guest_ws_api.execution_arn}/*"
}

###############################################################################
# 5. Authenticated WebSocket API (Cognito JWT)
#    (Reuses the same DynamoDB table, but separate code/integration)
###############################################################################
# For brevity, we skip the full Cognito config. You can use the example from 
# the previous conversation. We'll assume you have a user pool & user pool client, 
# and a Google IdP if needed. We'll just reference them here.
###############################################################################
# resource "aws_apigatewayv2_authorizer" "auth_ws_authorizer" {
#   api_id          = aws_apigatewayv2_api.guest_ws_api.id
#   name            = "MyWsRequestAuthorizer"
#   authorizer_type = "REQUEST"
#   authorizer_uri = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.auth_lambda.arn}/invocations"
#   identity_sources = ["route.request.header.Authorization"]  # or querystring, etc.
# }

###############################################################################
# 6. Outputs
###############################################################################
output "guest_websocket_url" {
  description = "Guest WebSocket endpoint"
  value       = "${aws_apigatewayv2_api.guest_ws_api.api_endpoint}/${aws_apigatewayv2_stage.guest_stage.name}"
}

# output "auth_websocket_url" {
#   description = "Auth (Cognito) WebSocket endpoint"
#   value       = "${aws_apigatewayv2_api.guest_ws_api.api_endpoint}/${aws_apigatewayv2_stage.auth_stage.name}"
# }
