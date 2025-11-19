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




# EBS Volume for manual EC2 instance
# EBS Volume for manual EC2 instance
resource "aws_ebs_volume" "manual_ec2_volume" {
  availability_zone = "us-east-1a"  # Same AZ as the manual instance
  size              = 5            # 20 GB
  type              = "gp3"         # General Purpose SSD
  encrypted         = true

  tags = {
    Name = "manual-ec2-volume"
  }
}

# Attach EBS volume to manual EC2 instance
resource "aws_volume_attachment" "manual_ec2_volume_attach" {
  device_name = "/dev/xvdh"  # Use /dev/sdh for additional volume
  volume_id   = aws_ebs_volume.manual_ec2_volume.id
  instance_id = aws_instance.ubuntu_ec2.id
  skip_destroy = true  # Prevent issues during Terraform destroy
}





resource "aws_instance" "ubuntu_ec2" {
  ami                         = "ami-00577b9fe23424613"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.demo_subnet["a"].id
  associate_public_ip_address = true
  iam_instance_profile        = data.aws_iam_role.ssm_role.name

  # Root volume configuration
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              # Update and install SSM agent
              sudo apt-get update -y
              sudo apt-get install -y amazon-ssm-agent
              sudo systemctl enable amazon-ssm-agent
              sudo systemctl start amazon-ssm-agent

              # Wait for EBS volume to be attached as /dev/xvdh
              while [ ! -b "/dev/xvdh" ]; do
                  echo "Waiting for EBS volume to be attached..."
                  sleep 5
              done

              # Check if disk is already formatted
              if ! blkid /dev/xvdh; then
                  echo "Formatting /dev/xvdh as ext4"
                  sudo mkfs -t ext4 /dev/xvdh
              fi
              
              # Create mount point
              sudo mkdir -p /mnt/data
              
              # Mount the volume
              sudo mount /dev/xvdh /mnt/data
              
              # Add to fstab for automatic mount on reboot
              echo '/dev/xvdh /mnt/data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
              
              # Set permissions
              sudo chown -R ubuntu:ubuntu /mnt/data
              sudo chmod -R 755 /mnt/data
              
              # Create a test file
              sudo -u ubuntu bash -c 'echo "This is manual instance EBS data" > /mnt/data/manual-test.txt'
              
              echo "Manual instance EBS volume mounted at /mnt/data"
              EOF

  tags = {
    Name = "Ubuntu-SSM-EC2"
  }
  monitoring = false
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
  image_id      = "ami-00577b9fe23424613"
  instance_type = "t2.micro"
  
  # Add IAM instance profile for EBS permissions
  iam_instance_profile {
    name = data.aws_iam_role.ssm_role.name
  }
  
  # Root volume
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.asg_sg.id]
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
# Update system
sudo apt-get update -y
sudo apt-get install -y amazon-ssm-agent awscli

sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(echo $AZ | sed 's/.$//')

echo "Starting EBS volume creation for instance: $INSTANCE_ID"

# Create EBS volume WITHOUT TAGS (remove --tag-specifications)
VOLUME_ID=$(aws ec2 create-volume \
    --region $REGION \
    --availability-zone $AZ \
    --size 5 \
    --volume-type gp3 \
    --encrypted \
    --query 'VolumeId' --output text)

if [ $? -eq 0 ]; then
    echo "Successfully created EBS volume: $VOLUME_ID"
    
    # Wait for volume to be available
    echo "Waiting for volume to be available..."
    aws ec2 wait volume-available --volume-ids $VOLUME_ID --region $REGION
    
    # Attach volume to instance
    echo "Attaching volume to instance..."
    aws ec2 attach-volume \
        --device /dev/xvdh \
        --instance-id $INSTANCE_ID \
        --volume-id $VOLUME_ID \
        --region $REGION
    
    # Wait for volume to be attached
    echo "Waiting for volume attachment..."
    counter=0
    max_attempts=30
    while [ $counter -lt $max_attempts ]; do
        if [ -b "/dev/xvdh" ]; then
            echo "EBS volume attached successfully"
            
            # Format and mount
            echo "Formatting and mounting volume..."
            sudo mkfs -t ext4 /dev/xvdh
            sudo mkdir -p /mnt/data
            sudo mount /dev/xvdh /mnt/data
            echo '/dev/xvdh /mnt/data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
            sudo chown -R ubuntu:ubuntu /mnt/data
            sudo chmod -R 755 /mnt/data
            
            # Create test file
            sudo -u ubuntu bash -c 'echo "Dynamic EBS volume created by ASG - Instance: $(hostname)" > /mnt/data/dynamic-test.txt'
            echo "Dynamic EBS volume created and mounted at /mnt/data"
            break
        fi
        echo "Attempt $((counter + 1)): Volume not attached yet..."
        sleep 5
        ((counter++))
    done
    
    if [ $counter -eq $max_attempts ]; then
        echo "Failed to attach volume after $max_attempts attempts"
    fi
else
    echo "Failed to create EBS volume. Check IAM permissions."
fi




# === MOUNT EFS AND COPY FILES ===
echo "Setting up EFS for file copy..."

# Create EFS mount point
sudo mkdir -p /mnt/efs

# Mount EFS using access point
echo "Mounting EFS..."
sudo mount -t efs -o tls,accesspoint=${aws_efs_access_point.app_files_ap.id} ${aws_efs_file_system.app_files.id}:/ /mnt/efs

# Make EFS mount persistent
echo "${aws_efs_file_system.app_files.id} /mnt/efs efs tls,accesspoint=${aws_efs_access_point.app_files_ap.id},_netdev 0 0" | sudo tee -a /etc/fstab

# Wait for EFS to be mounted
sleep 10

# === COPY FILES FROM EFS TO EBS ===
echo "Copying files from EFS to local EBS volume..."

# Check if EFS has files to copy
if [ -d "/mnt/efs" ] && [ "$(ls -A /mnt/efs 2>/dev/null)" ]; then
    echo "Found files in EFS, copying to /mnt/data..."
    
    # Copy all files from EFS to EBS volume
    sudo cp -r /mnt/efs/* /mnt/data/ 2>/dev/null || true
    
    # Set proper permissions on copied files
    sudo chown -R ubuntu:ubuntu /mnt/data/
    sudo chmod -R 755 /mnt/data/
    
    echo "Files successfully copied from EFS to EBS volume"
    
    # List copied files for verification
    echo "Copied files:"
    ls -la /mnt/data/
else
    echo "No files found in EFS or EFS is empty"
    
    # Create a marker file to show EFS was accessed
    sudo -u ubuntu bash -c 'echo "EFS was mounted but no files were found for copying. Instance: $(hostname)" > /mnt/data/efs-copy-status.txt'
fi

# === UNMOUNT EFS (OPTIONAL) ===
# If you don't need EFS mounted after copying, unmount it
echo "Unmounting EFS after file copy..."
sudo umount /mnt/efs
# Remove from fstab if you don't want persistent mount
sudo sed -i '/efs/d' /etc/fstab

# Create final test file
sudo -u ubuntu bash -c 'echo "ASG instance setup completed. Files copied from EFS to EBS. Instance: $(hostname) - $(date)" > /mnt/data/setup-complete.txt'

echo "Instance setup completed successfully"
echo "EFS files copied to EBS volume at /mnt/data"




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








# EFS Security Group
resource "aws_security_group" "efs_sg" {
  name_prefix = "efs-sg"
  description = "Security group for EFS"
  vpc_id      = aws_vpc.demo_vpc.id

  # Allow NFS traffic from ASG security group
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.asg_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-sg"
  }
}

# EFS File System
resource "aws_efs_file_system" "app_files" {
  creation_token   = "app-files-efs"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name = "app-files-efs"
  }
}

# EFS Mount Targets in each subnet
resource "aws_efs_mount_target" "efs_mount_targets" {
  for_each = aws_subnet.demo_subnet

  file_system_id  = aws_efs_file_system.app_files.id
  subnet_id       = each.value.id
  security_groups = [aws_security_group.efs_sg.id]
}

# EFS Access Point for app files
resource "aws_efs_access_point" "app_files_ap" {
  file_system_id = aws_efs_file_system.app_files.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/app"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  tags = {
    Name = "app-files-access-point"
  }
}





