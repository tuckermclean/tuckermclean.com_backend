# Terraform Script for Infrastructure-as-Code Setup
# Components: S3 bucket, HTTPS CloudFront, Route53, API Gateway, and Hello World Lambda

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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

  subject_alternative_names = ["www.technomantics.com","api.technomantics.com","auth.technomantics.com"]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "technomantics.com certificate"
  }
}

resource "aws_acm_certificate" "api_cert" {
  provider = aws.us_west_2

  domain_name       = "api.technomantics.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "api.technomantics.com certificate"
  }
}