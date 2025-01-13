

output "nameservers" {
  value = aws_route53_zone.main_zone.name_servers
}

output "api_base_url" {
  description = "Guest WebSocket endpoint"
  value       = "${aws_apigatewayv2_api.guest_ws_api.api_endpoint}/${aws_apigatewayv2_stage.guest_stage.name}"
}

output "domain_name" {
  value = var.domain_name[terraform.workspace]
}

output "google_client_id" {
  value = var.google_client_id[terraform.workspace]
  sensitive = true
}

output "google_client_secret" {
  value = var.google_client_secret[terraform.workspace]
  sensitive = true
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.pool.id
}