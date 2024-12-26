
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "api_endpoint" {
  value = aws_api_gateway_stage.api_stage.invoke_url
}

output "nameservers" {
  value = aws_route53_zone.main_zone.name_servers
}

