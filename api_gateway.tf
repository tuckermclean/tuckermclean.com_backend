resource "aws_api_gateway_rest_api" "hello_api" {
  name = "HelloWorldAPI"
}

# Define the /hello resource
resource "aws_api_gateway_resource" "hello" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
  parent_id   = aws_api_gateway_rest_api.hello_api.root_resource_id
  path_part   = "hello"
}

# POST method for /hello
resource "aws_api_gateway_method" "post_hello" {
  rest_api_id   = aws_api_gateway_rest_api.hello_api.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "POST"
  authorization = "NONE"
}

# Integration for the POST method with Lambda
resource "aws_api_gateway_integration" "post_hello_integration" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
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
  rest_api_id   = aws_api_gateway_rest_api.hello_api.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "GET"
  authorization = "NONE"
}

# Integration for the GET method with Lambda
resource "aws_api_gateway_integration" "get_hello_integration" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
  resource_id = aws_api_gateway_method.get_hello.resource_id
  http_method = aws_api_gateway_method.get_hello.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.hello_lambda.invoke_arn
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

# OPTIONS method for /hello
resource "aws_api_gateway_method" "options_hello" {
  rest_api_id   = aws_api_gateway_rest_api.hello_api.id
  resource_id   = aws_api_gateway_resource.hello.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Integration for the OPTIONS method with Lambda
resource "aws_api_gateway_integration" "options_hello_integration" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.options_hello.http_method
  integration_http_method = "OPTIONS"
  type        = "MOCK"
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_integration_response" "options_hello_proxy" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
  resource_id = aws_api_gateway_integration.options_hello_integration.resource_id
  http_method = aws_api_gateway_method.options_hello.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-User-Agent'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# Method response for OPTIONS
resource "aws_api_gateway_method_response" "options_hello_proxy" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.options_hello.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

# Deploy the API Gateway
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id

  depends_on = [
    aws_api_gateway_integration.post_hello_integration,
    aws_api_gateway_integration.get_hello_integration,
    aws_api_gateway_integration.options_hello_integration,
  ]
}

# Create a stage for the API Gateway
resource "aws_api_gateway_stage" "api_stage" {
  stage_name    = "v1"
  rest_api_id   = aws_api_gateway_rest_api.hello_api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
}

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

  source_arn = "${aws_api_gateway_rest_api.hello_api.execution_arn}/*/*"
}

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
  api_id = aws_api_gateway_rest_api.hello_api.id
}