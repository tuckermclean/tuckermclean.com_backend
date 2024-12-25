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

resource "aws_s3_bucket" "website_bucket" {
  provider = aws.us_west_2
  bucket   = "technomantics.com"
}

resource "aws_s3_bucket_website_configuration" "website_bucket" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_public_access_block" "website_bucket_public_access_block" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.website_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website_bucket_policy" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.website_bucket.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::technomantics.com/*"
    }
  ]
}
POLICY
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

resource "aws_route53_zone" "main_zone" {
  name = "technomantics.com"
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.website_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = aws_route53_zone.main_zone.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id   = "S3-Website"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["technomantics.com", "www.technomantics.com"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Website"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      headers      = ["Host"]
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.website_cert.arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method  = "sni-only"
  }

  depends_on = [aws_acm_certificate.website_cert]
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "technomantics.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "www.technomantics.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
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

resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"

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

resource "aws_iam_role_policy_attachment" "lambda_exec_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_api_gateway_rest_api" "hello_api" {
  name        = "HelloWorldAPI"
  description = "Hello World API"
}

resource "aws_api_gateway_resource" "root" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id
  parent_id   = aws_api_gateway_rest_api.hello_api.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "get_method" {
  rest_api_id   = aws_api_gateway_rest_api.hello_api.id
  resource_id   = aws_api_gateway_resource.root.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.hello_api.id
  resource_id             = aws_api_gateway_resource.root.id
  http_method             = aws_api_gateway_method.get_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.hello_world.invoke_arn
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.hello_api.id

  depends_on = [aws_api_gateway_integration.lambda_integration]
}

resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.hello_api.id
  stage_name    = "v1"
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "api_endpoint" {
  value = aws_api_gateway_stage.api_stage.invoke_url
}

output "nameservers" {
  value = aws_route53_zone.main_zone.name_servers
}
