

output "nameservers" {
  value = aws_route53_zone.main_zone.name_servers
}

output "api_base_url" {
  description = "Guest WebSocket endpoint"
  value       = "wss://api.${var.domain_name[terraform.workspace]}/"
}

output "domain_name" {
  value = var.domain_name[terraform.workspace]
}

output "google_client_id" {
  value = var.google_client_id[terraform.workspace]
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.pool.id
}