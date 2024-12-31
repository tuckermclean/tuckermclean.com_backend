####
# Push notification key
# Methods: GET, POST
####

# Define the /push-key resource
resource "aws_api_gateway_resource" "conversation" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "conversation"
}

# GET method for /push-key
resource "aws_api_gateway_method" "get_conversation" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.conversation.id
  http_method   = "GET"
  authorization = "NONE"
}

# POST method for /push-key
resource "aws_api_gateway_method" "post_conversation" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.conversation.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integration for the GET method with Lambda
resource "aws_api_gateway_integration" "get_conversation" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.conversation.id
  http_method = aws_api_gateway_method.get_conversation.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.conversation.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

# Integration for the POST method with Lambda
resource "aws_api_gateway_integration" "post_conversation" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.conversation.id
  http_method = aws_api_gateway_method.post_conversation.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.conversation.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

####
# Lambda for push notification public key
####

# Package archive file for push key Lambda
data "archive_file" "conversation" {
  type = "zip"
  source_dir = "conversation"
  output_path = "conversation.zip"
}

# Lambda for retrieving push notification public key
resource "aws_lambda_function" "conversation" {
  filename = "conversation.zip"
  function_name = "conversation"
  role = aws_iam_role.conversation.arn
  source_code_hash = data.archive_file.conversation.output_base64sha256
  handler = "index.handler"
  runtime = "nodejs18.x"
}

# Lambda permission for push key Lambda
resource "aws_lambda_permission" "conversation" {
  statement_id = "AllowExecutionFromAPIGateway"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.conversation.function_name
  principal = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

####
# IAM roles and policies
####

resource "aws_iam_role" "conversation" {
  name = "conversation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "conversation_exec" {
  role       = aws_iam_role.conversation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "conversation" {
  name        = "conversation"
  description = "Policy to allow Lambda to access Secrets Manager"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action: [
          "secretsmanager:GetSecretValue",
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue"
        ],
        Effect: "Allow",
        Resource: [
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:VAPID_PUBLIC_KEY*",
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:VAPID_PRIVATE_KEY*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "conversation" {
  role       = aws_iam_role.conversation.name
  policy_arn = aws_iam_policy.conversation.arn
}
