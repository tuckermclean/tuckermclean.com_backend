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

resource "aws_route53_record" "auth" {
  zone_id = aws_route53_zone.main_zone.zone_id
  name    = aws_cognito_user_pool_domain.pool.domain
  type    = "A"

  alias {
    name                   = aws_cognito_user_pool_domain.pool.cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.pool.cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

# resource "aws_route53_record" "api" {
#   zone_id = aws_route53_zone.main_zone.zone_id
#   name    = "api.technomantics.com"
#   type    = "A"

#   alias {
#     name                   = aws_apigatewayv2_domain_name.custom_domain.domain_name_configuration[0].target_domain_name
#     zone_id                = aws_apigatewayv2_domain_name.custom_domain.domain_name_configuration[0].hosted_zone_id
#     evaluate_target_health = false
#   }
# }

