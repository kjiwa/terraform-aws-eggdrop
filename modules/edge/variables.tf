variable "domain_name" {
  description = "Apex domain the status page is served from. Its Route 53 zone is zone_id."
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone ID for domain_name."
  type        = string
}

variable "token_key" {
  description = "localStorage key the sign-in page stores the status token under; the status page reads the same key."
  type        = string
}

variable "status_origins" {
  description = "Origins of the status page (modules/status origins output). One must be the S3 shell origin (custom_origin false): the default behavior needs an origin, though its function answers every request itself."
  type = list(object({
    origin_id                = string
    domain_name              = string
    origin_access_control_id = string
    custom_origin            = bool
  }))
}

variable "status_behaviors" {
  description = "Ordered cache behaviors of the status page (modules/status behaviors output). Each serves GET, HEAD and OPTIONS over HTTPS, compressed; function_arn attaches a viewer-request function when rewrite is true. Exact path patterns, never a wildcard: first match wins."
  type = list(object({
    path_pattern             = string
    origin_id                = string
    cache_policy_id          = string
    origin_request_policy_id = string
    function_arn             = string
    rewrite                  = bool
  }))
}
