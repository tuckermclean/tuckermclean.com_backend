resource "aws_api_gateway_rest_api" "api" {
  name = "API"
}

####
# Hello world
# Methods: POST, GET, OPTIONS
####

# Define the /hello resource
resource "aws_api_gateway_resource" "hello" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "hello"
}

# POST method for /hello
resource "aws_api_gateway_method" "post_hello" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integration for the POST method with Lambda
resource "aws_api_gateway_integration" "post_hello_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_method.post_hello.resource_id
  http_method = aws_api_gateway_method.post_hello.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.hello_lambda.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

# GET method for /hello
resource "aws_api_gateway_method" "get_hello" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration for the GET method with Lambda
resource "aws_api_gateway_integration" "get_hello_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_method.get_hello.resource_id
  http_method = aws_api_gateway_method.get_hello.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.hello_lambda.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

####
# Push notification key
# Methods: GET, POST
####

# Define the /push-key resource
resource "aws_api_gateway_resource" "push_key" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "push-key"
}

# GET method for /push-key
resource "aws_api_gateway_method" "get_push_key" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.push_key.id
  http_method   = "GET"
  authorization = "NONE"
}

# POST method for /push-key
resource "aws_api_gateway_method" "post_push_key" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.push_key.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integration for the GET method with Lambda
resource "aws_api_gateway_integration" "get_push_key_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.push_key.id
  http_method = aws_api_gateway_method.get_push_key.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.push_key.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

# Integration for the POST method with Lambda
resource "aws_api_gateway_integration" "post_push_key_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.push_key.id
  http_method = aws_api_gateway_method.post_push_key.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.push_key.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

####
# Deployment and stage
####

# Deploy the API Gateway
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  depends_on = [
    aws_api_gateway_integration.post_hello_integration,
    aws_api_gateway_integration.get_hello_integration,
    aws_api_gateway_integration.get_push_key_integration,
    aws_api_gateway_integration.post_push_key_integration
  ]
}

# Create a stage for the API Gateway
resource "aws_api_gateway_stage" "api_stage" {
  stage_name    = "v1"
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
}

####
# Lambda for hello world
####

data "archive_file" "hello_lambda_package" {
  type = "zip"
  source_file = "hello_world/index.js"
  output_path = "hello_world.zip"
}

resource "aws_lambda_function" "hello_lambda" {
  filename = "hello_world.zip"
  function_name = "HelloWorldFunction"
  role = aws_iam_role.lambda_exec.arn
  source_code_hash = data.archive_file.hello_lambda_package.output_base64sha256
  handler = "index.handler"
  runtime = "nodejs18.x"
}

resource "aws_lambda_permission" "hello_lambda" {
  statement_id = "AllowExecutionFromAPIGateway"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello_lambda.function_name
  principal = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

####
# Lambda for push notification public key
####

# Package archive file for push key Lambda
data "archive_file" "push_key" {
  type = "zip"
  source_dir = "push_key"
  output_path = "push_key.zip"
}

# Lambda for retrieving push notification public key
resource "aws_lambda_function" "push_key" {
  filename = "push_key.zip"
  function_name = "PushKeyFunction"
  role = aws_iam_role.lambda_exec.arn
  source_code_hash = data.archive_file.push_key.output_base64sha256
  handler = "index.handler"
  runtime = "nodejs18.x"
}

# Lambda permission for push key Lambda
resource "aws_lambda_permission" "push_key" {
  statement_id = "AllowExecutionFromAPIGateway"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.push_key.function_name
  principal = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

####
# Custom domain for API Gateway
####

resource "aws_api_gateway_domain_name" "custom_domain" {
  domain_name = "api.technomantics.com"
  regional_certificate_arn = aws_acm_certificate.api_cert.arn
  endpoint_configuration {
    types = ["REGIONAL"] # Use "EDGE" for global deployment via CloudFront
  }

  depends_on = [
    aws_acm_certificate.api_cert,
  ]
}

resource "aws_api_gateway_base_path_mapping" "base_path" {
  domain_name = aws_api_gateway_domain_name.custom_domain.domain_name
  api_id = aws_api_gateway_rest_api.api.id
}