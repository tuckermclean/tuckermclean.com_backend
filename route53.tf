resource "aws_route53_zone" "main_zone" {
  name = var.domain_name[terraform.workspace]
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


resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = var.domain_name[terraform.workspace]
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "www.${var.domain_name[terraform.workspace]}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "auth" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "auth.${var.domain_name[terraform.workspace]}"
  type    = "A"

  alias {
    name                   = aws_cognito_user_pool_domain.pool.cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.pool.cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "mx_root" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = var.domain_name[terraform.workspace]
  type    = "MX"
  ttl     = 300
  records = [
    "10 in1-smtp.messagingengine.com.",
    "20 in2-smtp.messagingengine.com.",
  ]
}

# MX record for the wildcard domain
resource "aws_route53_record" "mx_wildcard" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "*.${var.domain_name[terraform.workspace]}"
  type    = "MX"
  ttl     = 300
  records = [
    "10 in1-smtp.messagingengine.com.",
    "20 in2-smtp.messagingengine.com.",
  ]
}

# DKIM record for the root domain
resource "aws_route53_record" "dkim_dkim_fm1" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "fm1._domainkey.${var.domain_name[terraform.workspace]}"
  type    = "CNAME"
  ttl     = 300
  records = [
    "fm1.${var.domain_name[terraform.workspace]}.dkim.fmhosted.com.",
  ]
}

# DKIM for fm2
resource "aws_route53_record" "dkim_dkim_fm2" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "fm2._domainkey.${var.domain_name[terraform.workspace]}"
  type    = "CNAME"
  ttl     = 300
  records = [
    "fm2.${var.domain_name[terraform.workspace]}.dkim.fmhosted.com.",
  ]
}

# DKIM for fm3
resource "aws_route53_record" "dkim_dkim_fm3" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = "fm3._domainkey.${var.domain_name[terraform.workspace]}"
  type    = "CNAME"
  ttl     = 300
  records = [
    "fm3.${var.domain_name[terraform.workspace]}.dkim.fmhosted.com.",
  ]
}

# SPF record for the root domain
resource "aws_route53_record" "spf_root" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = var.domain_name[terraform.workspace]
  type    = "TXT"
  ttl     = 300
  records = [
    "v=spf1 include:spf.messagingengine.com ?all",
  ]
}

# resource "aws_route53_record" "api" {
#   zone_id = aws_route53_zone.main_zone.zone_id
#   name    = "api.${var.domain_name[terraform.workspace]}"
#   type    = "A"

#   alias {
#     name                   = aws_apigatewayv2_domain_name.custom_domain.domain_name_configuration[0].target_domain_name
#     zone_id                = aws_apigatewayv2_domain_name.custom_domain.domain_name_configuration[0].hosted_zone_id
#     evaluate_target_health = false
#   }
# }

