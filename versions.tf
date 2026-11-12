terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45"
      # CloudFront only accepts ACM certificates issued in us-east-1.
      configuration_aliases = [aws.us_east_1]
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
