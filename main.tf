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