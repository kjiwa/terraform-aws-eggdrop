mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

override_resource {
  target          = aws_acm_certificate.this
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    domain_validation_options = [
      { domain_name = "example.com", resource_record_name = "_a.example.com.", resource_record_type = "CNAME", resource_record_value = "a.acm.example." },
    ]
  }
}

variables {
  domain_name = "example.com"
  zone_id     = "Z0000000000000TEST"
  token_key   = "naju-token"
  status_origins = [
    { origin_id = "status-s3", domain_name = "bucket.s3.us-west-2.amazonaws.com", origin_access_control_id = "E1", custom_origin = false },
    { origin_id = "status-lambda", domain_name = "abc.lambda-url.us-west-2.on.aws", origin_access_control_id = "E2", custom_origin = true },
  ]
  status_behaviors = [
    { path_pattern = "/status", origin_id = "status-s3", cache_policy_id = "p1", origin_request_policy_id = null, function_arn = "arn:aws:cloudfront::123456789012:function/rewrite", rewrite = true },
    { path_pattern = "/status/data", origin_id = "status-lambda", cache_policy_id = "p2", origin_request_policy_id = "r1", function_arn = null, rewrite = false },
  ]
}

run "distribution_serves_only_the_status_page" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = aws_cloudfront_distribution.this.aliases == toset(["example.com"]) && length(aws_cloudfront_distribution.this.ordered_cache_behavior) == 2
    error_message = "The apex and the status behaviors only."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior).target_origin_id == "status-s3" && length(one(aws_cloudfront_distribution.this.default_cache_behavior).function_association) == 1
    error_message = "The default behavior must run the edge function, in front of the S3 shell origin."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.this.default_cache_behavior).viewer_protocol_policy == "redirect-to-https"
    error_message = "HTTPS only."
  }
}

run "edge_function_content" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.edge.code, "'/status'") || strcontains(aws_cloudfront_function.edge.code, "\"/status\"")
    error_message = "The apex must redirect to /status."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.edge.code, base64sha256(local.signin_script))
    error_message = "The content security policy must allow exactly the sign-in script."
  }

  assert {
    condition     = strcontains(local.signin_script, "\"naju-token\"") && strcontains(local.signin_script, "location.replace('/status')")
    error_message = "The sign-in page must store the token under token_key and go to the status page."
  }
}
