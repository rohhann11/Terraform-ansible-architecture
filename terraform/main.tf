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






# New S3 Bucket for application files
resource "aws_s3_bucket" "prime_square" {
  bucket = "prime-square"

  tags = {
    Name = "prime-square"
    Purpose = "application-files"
  }
}

# Block public access for the new bucket
resource "aws_s3_bucket_public_access_block" "prime_square_block" {
  bucket = aws_s3_bucket.prime_square.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload entire folder to S3 using null resource
resource "null_resource" "upload_folder_to_s3" {
  depends_on = [aws_s3_bucket.prime_square]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Uploading entire folder to S3..."
      aws s3 sync /home/ubuntu/folder/ s3://prime-square/prime-square/
      aws s3 sync /home/ubuntu/frontend/ s3://prime-square/frontend   

      echo "Files uploaded to S3:"
      aws s3 ls s3://prime-square/prime-square/ --recursive --human-readable
      aws s3 ls s3://prime-square/frontend/ --recursive --human-readable 

      echo "Upload completed successfully!"
    EOT
  }

  # Trigger upload on every apply to ensure latest files
  triggers = {
    always_run = timestamp()
  }
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






# === DOWNLOAD FILES FROM S3 PRIME_SQUARE BUCKET ===
echo "Setting up S3 file download from prime-square bucket..."

S3_BUCKET="prime-square"
S3_PREFIX="prime-square"

# Create download directory
sudo mkdir -p /mnt/data/prime-square

echo "Downloading files from S3 bucket: $S3_BUCKET"

# Check if S3 bucket exists and has files
if aws s3 ls "s3://$S3_BUCKET/" 2>/dev/null; then
    echo "S3 bucket accessible. Checking for files..."
    
    # Download entire folder from S3
    if aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" 2>/dev/null; then
        echo "Found folder in S3: $S3_PREFIX"
        echo "Starting folder download..."
        
        # Sync entire folder from S3 to local directory
        aws s3 sync "s3://$S3_BUCKET/$S3_PREFIX/" /mnt/data/prime-square/
        
        # Set proper permissions
        sudo chown -R ubuntu:ubuntu /mnt/data/prime-square/
        sudo chmod -R 755 /mnt/data/prime-square/
        
        # Make all shell scripts executable
        sudo find /mnt/data/prime-square/ -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
        
        echo "Folder successfully downloaded from S3"
        
        # List downloaded files for verification
        echo "Downloaded folder contents:"
        find /mnt/data/prime-square/ -type f -exec ls -la {} \;
        
        # Get file count
        FILE_COUNT=$(find /mnt/data/prime-square/ -type f | wc -l)
        echo "Total files downloaded: $FILE_COUNT"
        
        # Copy to main data directory (optional)
        echo "Copying files to main data directory..."
        sudo cp -r /mnt/data/prime-square/* /mnt/data/ 2>/dev/null || true
        
    else
        echo "No folder found in S3: $S3_PREFIX"
        echo "Available objects in bucket:"
        aws s3 ls s3://$S3_BUCKET/ --recursive || true
    fi
else
    echo "S3 bucket $S3_BUCKET not accessible or doesn't exist"
fi

# === PROCESS DOWNLOADED FILES ===
echo "Processing downloaded files..."

# Count and list all files
echo "Files in prime-square folder:"
find /mnt/data/prime-square/ -type f -printf "%f\n" | while read file; do
    echo "  - $file"
done

# Check for specific file types and set permissions
if [ -f "/mnt/data/prime-square/wrapper.sh" ]; then
    echo "Wrapper script found and made executable"
fi

if [ -f "/mnt/data/prime-square/encrypt.sh" ]; then
    echo "Encrypt script found and made executable"
fi

if [ -f "/mnt/data/prime-square/core-1.1.28_IIFL_1.1.15.jar" ]; then
    echo "JAR file found: core-1.1.28_IIFL_1.1.15.jar"
fi

if [ -f "/mnt/data/prime-square/application.properties" ]; then
    echo "Application properties file found"
    echo "First few lines:"
    head -n 3 /mnt/data/prime-square/application.properties
fi

# Create final test file
sudo -u ubuntu bash -c 'echo "ASG instance setup completed. Entire folder downloaded from S3. Instance: $(hostname) - $(date)" > /mnt/data/setup-complete.txt'
sudo -u ubuntu bash -c 'echo "Files downloaded: $(find /mnt/data/prime-square/ -type f | wc -l) files" >> /mnt/data/setup-complete.txt'

echo "Instance setup completed successfully"
echo "Entire S3 folder downloaded to /mnt/data/prime-square"






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










