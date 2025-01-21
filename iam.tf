####
# IAM resources for S3 bucket CI/CD
####

resource "aws_iam_user" "s3_user" {
  name = "s3-update-user"
}

resource "aws_iam_access_key" "s3_user_key" {
  user = aws_iam_user.s3_user.name
}

resource "aws_iam_policy" "s3_update_policy" {
  name        = "s3-update-policy"
  description = "Policy to allow updating of an S3 bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.domain_name[terraform.workspace]}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.domain_name[terraform.workspace]}"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "s3_update_policy_attachment" {
  name       = "s3-update-policy-attachment"
  policy_arn = aws_iam_policy.s3_update_policy.arn
  users      = [aws_iam_user.s3_user.name]
}

output "s3_access_key_id" {
  value = aws_iam_access_key.s3_user_key.id
}

output "s3_secret_access_key" {
  value     = aws_iam_access_key.s3_user_key.secret
  sensitive = true
}

####
# IAM resources for Terraform CI/CD
####

resource "aws_iam_user" "terraform_user" {
  name = "terraform-update-user"
}

resource "aws_iam_access_key" "terraform_user_key" {
  user = aws_iam_user.terraform_user.name
}

resource "aws_iam_policy" "terraform_update_policy" {
  name        = "terraform-update-policy"
  description = "Policy to allow updating of Terraform resources"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = {
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
    }
  })
}

resource "aws_iam_policy_attachment" "terraform_update_policy_attachment" {
  name       = "terraform-update-policy-attachment"
  policy_arn = aws_iam_policy.terraform_update_policy.arn
  users      = [aws_iam_user.terraform_user.name]
}

output "terraform_access_key_id" {
  value = aws_iam_access_key.terraform_user_key.id
}

output "terraform_secret_access_key" {
  value     = aws_iam_access_key.terraform_user_key.secret
  sensitive = true
}