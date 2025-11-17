resource "aws_vpc" "demo_vpc" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {

    Name = "pinpointx"
  }
}


locals {
  subnet_azs = {
    a = "us-east-1a"
    b = "us-east-1b"
  }
}

resource "aws_subnet" "demo_subnet" {
  for_each = local.subnet_azs

  vpc_id                  = aws_vpc.demo_vpc.id
  cidr_block              = each.key == "a" ? "10.0.0.0/25" : "10.0.0.128/25"
  availability_zone       = each.value
  map_public_ip_on_launch = true

  tags = {
    Name = "pinpoint-subnet-${each.value}"
  }
}



resource "aws_internet_gateway" "demo_igw" {
  vpc_id = aws_vpc.demo_vpc.id

  tags = {
    Name = "pinpoint-igw"
  }
}


resource "aws_route_table" "demo_route_table" {
  vpc_id = aws_vpc.demo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo_igw.id
  }

  tags = {
    Name = "pinpoint-route-table"
  }
}



resource "aws_route_table_association" "demo_route_table_association" {
  for_each = aws_subnet.demo_subnet

  subnet_id      = each.value.id
  route_table_id = aws_route_table.demo_route_table.id
}





data "aws_iam_role" "ssm_role" {
  name = "SSMinstanceRole" # Use the existing role name
}



resource "aws_instance" "ubuntu_ec2" {
  ami                         = "ami-00577b9fe23424613" # Ubuntu 20.04 LTS in us-east-1 (find the latest AMI for your region)
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.demo_subnet["a"].id
  associate_public_ip_address = true

  # Attach the existing SSM IAM Role
  iam_instance_profile = data.aws_iam_role.ssm_role.name

  # Install SSM agent if it's not already installed (optional)
  user_data = <<-EOF
              #!/bin/bash
              # Update and install SSM agent
              sudo apt-get update -y
              sudo apt-get install -y amazon-ssm-agent
              sudo systemctl enable amazon-ssm-agent
              sudo systemctl start amazon-ssm-agent
              EOF

  tags = {
    Name = "Ubuntu-SSM-EC2"
  }

  monitoring = false # Enable detailed monitoring (optional)
}


# Output the EC2 instance public IP (or private IP based on your needs)
output "instance_public_ip" {
  value = aws_instance.ubuntu_ec2.public_ip
}





resource "aws_s3_bucket" "ansible_bucket" {
  bucket = "my-ansible-s3-bucketx"

  tags = {
    Name = "my-ansible-s3-bucketx"

  }
}




resource "aws_s3_bucket_public_access_block" "ansible_bucket_block" {
  bucket = aws_s3_bucket.ansible_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}











# Step 1: Create a Security Group for the EC2 instance
resource "aws_security_group" "asg_sg" {
  name_prefix = "asg-sg"
  description = "Allow inbound traffic to EC2 instances in the Auto Scaling group"
  vpc_id      = aws_vpc.demo_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Step 2: Create a Load Balancer (Application Load Balancer)
resource "aws_lb" "example" {
  name               = "example-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.asg_sg.id]

  # Collect all subnet IDs from the looped subnets
  subnets = [for subnet in aws_subnet.demo_subnet : subnet.id]
}

# Step 3: Create a Target Group for the Load Balancer
resource "aws_lb_target_group" "example" {
  name     = "example-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo_vpc.id # Replace with your VPC ID
}


# Step 5: Register the EC2 instance with the Target Group (manually)
resource "aws_lb_target_group_attachment" "manual_instance_attachment" {
  target_group_arn = aws_lb_target_group.example.arn
  target_id        = aws_instance.ubuntu_ec2.id
  port             = 80
}

# Step 6: Auto Scaling Group (ASG) setup
resource "aws_launch_template" "asg_launch_template" {
  name          = "asg-launch-template"
  image_id      = "ami-00577b9fe23424613" # Use your own AMI
  instance_type = "t2.micro"
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.asg_sg.id]
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
echo "Running startup scripts"
EOF
  )
}

resource "aws_autoscaling_group" "asg" {
  desired_capacity          = 1
  max_size                  = 3
  min_size                  = 1
  vpc_zone_identifier       = [for subnet in aws_subnet.demo_subnet : subnet.id] # Replace with your subnet ID
  health_check_type         = "EC2"
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.asg_launch_template.id
    version = "$Latest"
  }
  # Attach the Auto Scaling Group to the Target Group
  target_group_arns = [aws_lb_target_group.example.arn]
}


# Scale-Out Policy (add instances when load is high)
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale-out-cpu"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300 # 5 minutes
  autoscaling_group_name = aws_autoscaling_group.asg.name
}

# Scale-In Policy (remove instances when load is low)
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "scale-in-cpu"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300 # 5 minutes
  autoscaling_group_name = aws_autoscaling_group.asg.name
}



# Alarm to trigger Scale-Out (high CPU)
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "asg-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120" # 2 minutes
  statistic           = "Average"
  threshold           = "70" # Scale out when CPU > 70%
  alarm_description   = "Scale out when CPU exceeds 70%"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# Alarm to trigger Scale-In (low CPU)
resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "asg-low-cpu"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "5" # Longer period to avoid flapping
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120" # 2 minutes
  statistic           = "Average"
  threshold           = "30" # Scale in when CPU < 30%
  alarm_description   = "Scale in when CPU below 30%"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}








# Output the ASG name
output "asg_name" {
  value = aws_autoscaling_group.asg.name
}





