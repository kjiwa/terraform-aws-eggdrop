data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Name = local.name
  }
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid     = "ReadBotBucket"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.this.arn}/config/*",
      "${aws_s3_bucket.this.arn}/eggdrop/*",
      "${aws_s3_bucket.this.arn}/secret/*",
    ]
  }

  # Without it a missing key answers 403 instead of 404, which hides the
  # difference between "not uploaded yet" and a policy mistake.
  statement {
    sid       = "ListBotBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "PublishHeartbeat"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = local.name
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = local.name
  role = aws_iam_role.instance.name
}
