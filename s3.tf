resource "aws_s3_bucket" "website_bucket" {
  provider = aws.us_west_2
  bucket   = "technomantics.com"

  provisioner "local-exec" {
    when    = create
    command = "aws s3 sync ../tuckermclean.com s3://${aws_s3_bucket.website_bucket.bucket} --delete --exclude \".git/*\""
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws s3 rm s3://technomantics.com --recursive"
  }
}

resource "aws_s3_bucket_website_configuration" "website_bucket" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_public_access_block" "website_bucket_public_access_block" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.website_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website_bucket_policy" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.website_bucket.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::technomantics.com/*"
    }
  ]
}
POLICY
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id   = "S3-Website"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  // Error page configuration
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/error.html"
    error_caching_min_ttl = 5
  }

  aliases = ["technomantics.com", "www.technomantics.com"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Website"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.website_cert.arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method  = "sni-only"
  }

}
