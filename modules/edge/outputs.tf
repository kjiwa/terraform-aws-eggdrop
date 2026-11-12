output "distribution_arn" {
  description = "CloudFront distribution ARN. The status module scopes its Lambda and bucket access to it."
  value       = aws_cloudfront_distribution.this.arn
}

output "url" {
  description = "Public HTTPS URL of the status page."
  value       = "https://${var.domain_name}/status"
}
