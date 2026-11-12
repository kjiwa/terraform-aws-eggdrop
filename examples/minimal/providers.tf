provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      Project   = "naju"
      ManagedBy = "terraform"
    }
  }
}

# CloudFront only accepts ACM certificates issued in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "naju"
      ManagedBy = "terraform"
    }
  }
}
