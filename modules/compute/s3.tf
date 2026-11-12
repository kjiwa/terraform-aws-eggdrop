# Holds what the instance pulls over the S3 gateway endpoint at boot: rendered
# config, the Eggdrop tarball (uploaded by scripts/upload.sh, not Terraform, so
# the pinned hash is checked before it lands here), and the status HMAC key.
resource "aws_s3_bucket" "this" {
  bucket_prefix = "${local.name}-bot-"
  # Everything in it is reproducible from the config and the pinned tarball.
  force_destroy = true

  tags = {
    Name = "${local.name}-bot"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_object" "config" {
  for_each = local.config_files

  bucket       = aws_s3_bucket.this.id
  key          = each.key
  content      = each.value
  content_type = "text/plain"
}

resource "aws_s3_object" "status_key" {
  bucket                 = aws_s3_bucket.this.id
  key                    = "secret/status.key"
  content                = var.status_key
  server_side_encryption = "AES256"
}
