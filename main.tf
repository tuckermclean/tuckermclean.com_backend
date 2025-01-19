terraform {
  backend "s3" {
    bucket         = "tuckermclean.com-terraform-state"
    key            = "terraform/state/tuckermclean.com"
    region         = "us-west-2"
    dynamodb_table = "arn:aws:dynamodb:us-west-2:276198986496:table/TerraformStateLock"
  }
}

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

  domain_name       = var.domain_name[terraform.workspace]
  validation_method = "DNS"

  subject_alternative_names = [
    "www.${var.domain_name[terraform.workspace]}",
    "api.${var.domain_name[terraform.workspace]}",
    "auth.${var.domain_name[terraform.workspace]}",
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.domain_name[terraform.workspace]} certificate"
  }
}

resource "aws_acm_certificate" "api_cert" {
  provider = aws.us_west_2

  domain_name       = "api.${var.domain_name[terraform.workspace]}"
  validation_method = "DNS"

  subject_alternative_names = [
    "api-ws.${var.domain_name[terraform.workspace]}",
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "api ${var.domain_name[terraform.workspace]} certificate"
  }
}