# iam.tf — the instance's identity. SSM Agent uses it to register with Session Manager;
# without AmazonSSMManagedInstanceCore the instance never shows up in `aws ssm start-session`.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "load" {
  name               = "${var.project}-load-generator"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.load.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 can't take a role directly; it takes an instance profile that wraps one role.
resource "aws_iam_instance_profile" "load" {
  name = "${var.project}-load-generator"
  role = aws_iam_role.load.name
}
