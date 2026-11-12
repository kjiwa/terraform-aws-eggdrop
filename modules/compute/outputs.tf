output "bucket_name" {
  description = "Bot bucket. scripts/upload.sh puts the Eggdrop tarball under eggdrop/ here."
  value       = aws_s3_bucket.this.id
}

output "asg_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.this.name
}
