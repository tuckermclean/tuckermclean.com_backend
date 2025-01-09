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
}

#####################################################################
# 5. API Gateway WebSocket
#####################################################################
resource "aws_apigatewayv2_api" "websocket_api" {
  name                = "MyChatWebSocketAPI"
  protocol_type       = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# Integration for all routes
resource "aws_apigatewayv2_integration" "websocket_integration" {
  api_id                = aws_apigatewayv2_api.websocket_api.id
  integration_type      = "AWS_PROXY"
  integration_uri       = aws_lambda_function.ws_handler_lambda.arn
  integration_method    = "POST"
}

#####################################################################
# 6. Routes: connect, disconnect, sendMessage
#####################################################################
resource "aws_apigatewayv2_route" "connect_route" {
  api_id    = aws_apigatewayv2_api.websocket_api.id
  route_key = "$connect"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.websocket_integration.id}"
}

resource "aws_apigatewayv2_route" "disconnect_route" {
  api_id    = aws_apigatewayv2_api.websocket_api.id
  route_key = "$disconnect"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.websocket_integration.id}"
}

resource "aws_apigatewayv2_route" "sendmessage_route" {
  api_id    = aws_apigatewayv2_api.websocket_api.id
  route_key = "sendMessage"

  authorization_type = "NONE"
  target            = "integrations/${aws_apigatewayv2_integration.websocket_integration.id}"
}

#####################################################################
# 7. Stage
#####################################################################
resource "aws_apigatewayv2_stage" "websocket_stage" {
  api_id      = aws_apigatewayv2_api.websocket_api.id
  name        = "prod"
  auto_deploy = true
}

#####################################################################
# 8. Permissions so API Gateway can invoke Lambda
#####################################################################
resource "aws_lambda_permission" "apigw_permission" {
  statement_id  = "AllowWebSocketInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ws_handler_lambda.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.websocket_api.execution_arn}/*"
}

#####################################################################
# 9. Output the WebSocket URL
#####################################################################
output "websocket_url" {
  description = "The WebSocket URL to connect to"
  value       = "${aws_apigatewayv2_api.websocket_api.api_endpoint}/${aws_apigatewayv2_stage.websocket_stage.name}"
}
