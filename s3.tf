resource "aws_s3_bucket" "website_bucket" {
  provider = aws.us_west_2
  bucket   = var.domain_name[terraform.workspace]
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
      "Resource": "arn:aws:s3:::${var.domain_name[terraform.workspace]}/*"
    }
  ]
}
POLICY
}

resource "aws_cloudfront_function" "rewrite_index" {
  name    = "rewrite-index-html"
  runtime = "cloudfront-js-1.0"
  comment = "Rewrite /foo/ to /foo/index.html"
  publish = true

  code = <<EOF
function handler(event) {
    var request = event.request;
    if (request.uri.endsWith('/')) {
        request.uri += 'index.html';
    }
    return request;
}
EOF
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id   = var.domain_name[terraform.workspace]
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

  aliases = [
    var.domain_name[terraform.workspace],
    "www.${var.domain_name[terraform.workspace]}",
  ]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = var.domain_name[terraform.workspace]
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite_index.arn
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
