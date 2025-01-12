###############################################################################
# 2. Cognito User Pool
###############################################################################
resource "aws_cognito_user_pool" "pool" {
  name                = "pool"
  mfa_configuration   = "OFF"

  # Basic password policy if you want local users. 
  # If you ONLY want Google, you can still set minimal config here.
  password_policy {
    minimum_length    = 8
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }
  
#   # Optional, but recommended
#   schema {
#     attribute_data_type = "String"
#     name                = "email"
#     required            = true
#   }
}

# Add a group for admin users
resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.pool.id
}

###############################################################################
# 3. Cognito User Pool Domain (for the Hosted UI, if you use it)
###############################################################################
resource "aws_cognito_user_pool_domain" "pool" {
  domain       = "auth.${var.domain_name[terraform.workspace]}"  # must be globally unique
  certificate_arn = aws_acm_certificate.website_cert.arn
  user_pool_id = aws_cognito_user_pool.pool.id
}

###############################################################################
# 4. Cognito Identity Provider (Google)
###############################################################################
resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.pool.id
  provider_name = "Google"  # Matches 'provider_type' below

  provider_type = "Google"
  provider_details = {
    # Provide your own Google OAuth 2.0 client info here
    client_id                = var.google_client_id[terraform.workspace]
    client_secret            = var.google_client_secret[terraform.workspace]
    authorize_scopes         = "openid email profile"
    oidc_issuer              = "https://accounts.google.com"
  }

  # Map Google attributes to Cognito attributes
  attribute_mapping = {
    email    = "email"
    username = "sub"
    name     = "name"
    phone_number = "phone_number"
    phone_number_verified = "phone_number_verified"
 }
}

###############################################################################
# 5. Cognito User Pool Client
###############################################################################
resource "aws_cognito_user_pool_client" "pool" {
  name                       = "pool"
  user_pool_id               = aws_cognito_user_pool.pool.id
  generate_secret            = false
  allowed_oauth_flows_user_pool_client = true

  # If you want to use the Cognito Hosted UI
  allowed_oauth_flows = ["code"]
  allowed_oauth_scopes = ["openid", "email", "profile"]

  # This ensures the user pool client can use 'Google' as an IdP.
  supported_identity_providers = [
    "COGNITO",       # optional if you allow direct Cognito sign-in
    aws_cognito_identity_provider.google.provider_name
  ]

  callback_urls = [
    # Where you want Cognito to redirect back after authentication
    "https://${var.domain_name[terraform.workspace]}/callback.html", 
  ]
  logout_urls = [
    "https://${var.domain_name[terraform.workspace]}/logout.html"
  ]
}
