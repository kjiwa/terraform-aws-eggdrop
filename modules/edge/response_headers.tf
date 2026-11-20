# Security headers on every behavior of the distribution. The CSP carries only
# frame-ancestors, so it cannot break the status page's scripts or styles;
# override = false lets an origin CSP or frame option win. HSTS omits
# includeSubdomains and preload: they bind every subdomain of the apex, which
# this module does not own.
resource "aws_cloudfront_response_headers_policy" "this" {
  name    = "eggdrop-security-headers"
  comment = "HSTS, nosniff, referrer policy and frame-ancestors for eggdrop (${var.domain_name})."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = false
    }

    content_security_policy {
      content_security_policy = "frame-ancestors 'self'"
      override                = false
    }
  }
}
