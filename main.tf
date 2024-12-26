# Terraform Script for Infrastructure-as-Code Setup
# Components: S3 bucket, HTTPS CloudFront, Route53, API Gateway, and Hello World Lambda

provider "aws" {
  alias   = "us_west_2"
  region  = "us-west-2" # Adjust region as necessary
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1" # Adjust region as necessary
}

resource "aws_acm_certificate" "website_cert" {
  provider = aws.us_east_1

  domain_name       = "technomantics.com"
  validation_method = "DNS"

  subject_alternative_names = ["www.technomantics.com"]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "technomantics.com certificate"
  }
}

resource "aws_lambda_function" "hello_world" {
  filename         = "hello_world.zip" # Zip the function and provide the path
  function_name    = "hello_world"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x" # Adjust runtime as necessary
  source_code_hash = filebase64sha256("hello_world.zip")
}
