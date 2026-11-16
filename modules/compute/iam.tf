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

  # The ARN is built from the literal names: the ASG's launch template embeds
  # this policy's dependencies through user_data.
  statement {
    sid       = "CompleteLaunchHook"
    effect    = "Allow"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = ["arn:aws:autoscaling:${data.aws_region.current.region}:${data.aws_caller_identity.default.account_id}:autoScalingGroup:*:autoScalingGroupName/${local.name}"]
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

  # Each bot writes its own snapshot, which the status page reads.
  statement {
    sid       = "WriteBotSnapshot"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/bots/*"]
  }

  statement {
    sid       = "WriteServerEvents"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.irc.arn}:*"]
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
