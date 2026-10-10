#!/usr/bin/env bash
# =====================================================================
# opencsusm.sh  
# CS 446 Midterm: OpenCSUSM
# Name: Amanda Chaaban               
# Fork: OpenCSUSM33664
#
#		I chose to use CPU running Ollama on an m7i-flex.large instance with
#	2 vCPU and 8 GB RAM for several reasons. First, stage 1 showed my GPU
#	G-instance quota is 0, so a GPU instance could not launch without waiting on 
#	AWS support to approve an increase. Additionally, Ollama is less 
#	restrictive than vLLM given that it does not need a GPU, an NVIDIA driver, or 
#	a quota increase. Second, my AWS Free Plan account only allows free-tier-eligible 
#	instance types. It refused the c7i.2xlarge from slide two of the 'CS 446 Week 8 — 
#	Serverless and event-driven architecture' lecture slides, so I chose m7i-flex.large 
#	which is the free-tier type with the most memory. Next, this assignment only tests a 
#	short greeting, so I used qwen2.5:0.5b because it is the smallest model that passes. 
#	It needs about 1 GB of the 8 GB, and a GPU or bigger model would increase the cost 
#	without any benefit. Cost is always an important factor to consider and CPU with Ollama 
#	is cheaper.Furthermore, it is safer given that Ollama only listens on localhost:11434, 
#	only port 22 is open and only to my IP, and I reach the model through an SSH tunnel, so 
#	the model is never exposed to the internet. Additionally, Ollama starts itself after 
#	installing, which means fewer steps that can fail.Ollama has some drawbacks such as being 
#	built for one user at a time, using quantized weights that can give lower quality answers 
#	on difficult tasks, and it can be slow with bigger models. However, those drawbacks do not 
#	apply to this project's scope, so CPU with Ollama was the best choice for this midterm. 
#
# =====================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1          # For clean Windows paths using Git Bash. 
export AWS_PAGER=""                

REGION="us-east-1"
TYPE="m7i-flex.large"              
MODEL="qwen2.5:0.5b"               
PORT=11434                         
KEYNAME="opencsusm-key"
SGNAME="opencsusm-sg"
TAG="opencsusm"                    
COURSE="CS446"                     
                                   
STATE=".opencsusm.state"           # Remembers the instance id and address between stages.
KEY="$HOME/.ssh/$KEYNAME.pem"
export AWS_DEFAULT_REGION="$REGION"

# One command per stage. Stages 3 and 4 run on the instance over ssh.

# Error handling: Prints warning for running other stages before stage 2. 
load() { if [ -f "$STATE" ]; then source "$STATE"; else echo "Run stage 2 first."; exit 1; fi; }

# Writes instance ID, address, and firewall group into .opencsusm.state.
save() { echo "$1=\"$2\"" >> "$STATE"; }

# Shortcut for running commands on the instance over SSH.
on_box() { ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ubuntu@$DNS" "$@"; }

# Reads stage number.
case "${1:-}" in

1)  # Stage 1: Quota & live price.
    aws sts get-caller-identity --query Account --output text
    aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
      --query '{quota:Quota.QuotaName,vCPUs:Quota.Value}' --output table
    aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
      --query '{quota:Quota.QuotaName,vCPUs:Quota.Value}' --output table
    aws ec2 describe-instance-type-offerings --location-type region \
      --filters Name=instance-type,Values=$TYPE \
      --query 'InstanceTypeOfferings[].InstanceType' --output text
    echo "On-demand price for $TYPE per hour:"
    aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters Type=TERM_MATCH,Field=instanceType,Value=$TYPE \
                Type=TERM_MATCH,Field=regionCode,Value=us-east-1 \
                Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
                Type=TERM_MATCH,Field=tenancy,Value=Shared \
                Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
                Type=TERM_MATCH,Field=capacitystatus,Value=Used \
      --query 'PriceList[0]' --output text \
      | grep -o '"OnDemand".*' | grep -o '"USD":"[0-9.]*"' | head -1 || true    
   # Error handling: finds free tier elgible types.
    aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
      --query 'InstanceTypes[].InstanceType' --output text
   # Error handling: checks that default VPC's internet route is active and not a blackhole. 
    aws ec2 describe-route-tables --filters Name=route.destination-cidr-block,Values=0.0.0.0/0 \
      "Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)" \
      --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,State][]' --output text
    ;;

2)  # Stage 2: Launches one instance, prints the ssh line, and the meter starts here. 
    # Starts a fresh state file so old instance details aren't reused.
    rm -f "$STATE"
    # Looks up my public IP so port 22 can be limited to it.
    MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '\r\n')
    # Makes sure the key folder exists and removes any old key so reruns don't fail.
    mkdir -p "$HOME/.ssh"
    aws ec2 delete-key-pair --key-name "$KEYNAME" 2>/dev/null || true
    rm -f "$KEY"
    # Creates the key pair and saves the private key for ssh. Tags every resources for stage 8.
    aws ec2 create-key-pair --key-name "$KEYNAME" \
      --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$TAG},{Key=Course,Value=$COURSE}]" \
      --query KeyMaterial --output text > "$KEY"
    # Locks the key file, since ssh refuses a private key that other users can read.
    chmod 400 "$KEY"
    # Finds the default VPC for security group.
    VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
      --query 'Vpcs[0].VpcId' --output text)
    # Creates the security group, or reuses it if it already exists.
    SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SGNAME \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
    if [ "$SG" = "None" ]; then
      SG=$(aws ec2 create-security-group --group-name "$SGNAME" \
        --description "OpenCSUSM ssh only" --vpc-id "$VPC" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$TAG},{Key=Course,Value=$COURSE}]" \
        --query GroupId --output text)
    fi
    # Opens port 22 to my IP only, and skips the error if the rule already exists.
    aws ec2 authorize-security-group-ingress --group-id "$SG" \
      --protocol tcp --port 22 --cidr "$MYIP/32" >/dev/null 2>&1 || true
    # Looks up the current Ubuntu image ID.
    AMI=$(aws ssm get-parameter \
      --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
      --query Parameter.Value --output text)
    # Launches the instance. 20 GB disk fits Ollama and the model, and is deleted together.
    IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" \
      --key-name "$KEYNAME" --security-group-ids "$SG" \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$TAG},{Key=Course,Value=$COURSE}]" \
                           "ResourceType=volume,Tags=[{Key=Project,Value=$TAG},{Key=Course,Value=$COURSE}]" \
      --query 'Instances[0].InstanceId' --output text)
    # Waits until the instance is running so its address exists.
    aws ec2 wait instance-running --instance-ids "$IID"
    # Gets the instance's public address.
    DNS=$(aws ec2 describe-instances --instance-ids "$IID" \
      --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
    # Saves the details for next stages.
    save SG "$SG"; save IID "$IID"; save DNS "$DNS"
    # Prints the ssh line. The meter is now running.
    echo "Running $IID - meter is ON. Wait ~30 s for SSH, then:"
    echo "ssh -i $KEY ubuntu@$DNS"
    ;;

3)  # Stage 3: Installs Ollama on the instance.
    # Loads the instance details saved in stage 2.
    load
    # Runs Ollama's installer over ssh and checks that the service is running.
    on_box 'curl -fsSL https://ollama.com/install.sh | sh && systemctl is-active ollama'
    ;;

4)  # Stage 4: Downloads the model on the instance.
    # Loads the instance details saved in stage 2.
    load
    # Pulls the model over ssh, then lists Ollama's models to confirm it loaded.
    on_box "ollama pull $MODEL && curl -s localhost:$PORT/api/tags"
    ;;

5)  # Stage 5: Prints the tunnel command for a second terminal.
    # Loads the instance details saved in stage 2.
    load
    # Prints the tunnel command. -N opens no shell; -L carries laptop port
    # 11434 through ssh (port 22) to port 11434 on the instance.
    echo "ssh -i $KEY -N -L $PORT:localhost:$PORT ubuntu@$DNS"
    ;;

6)  # Stage 6: Sends "I am John" through the tunnel.
    # Sends the test message. Localhost is my desktop. The tunnel carries it
    # to the model. Temperature 0 gives the same answer every time.
    curl -sS localhost:$PORT/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"I am John\"}], \"max_tokens\": 20, \"temperature\": 0}"
    # Adds a line break after the reply.
    echo
    ;;

7)  # Stage 7: Stops the instance. Compute billing ends, but the disk still bills.
    # Loads the instance details saved in stage 2.
    load
    # Stops the instance.
    aws ec2 stop-instances --instance-ids "$IID" >/dev/null
    # Waits until it has fully stopped.
    aws ec2 wait instance-stopped --instance-ids "$IID"
    # Prints a reminder to run stage 8.
    echo "Stopped $IID (disk still billing - run stage 8)."
    ;;

8)  # Stage 8: Deletes everything and proves it. Both checks print nothing.
    # Loads the instance details saved in stage 2.
    load
    # Deletes the instance. Its disk is deleted with it.
    aws ec2 terminate-instances --instance-ids "$IID" >/dev/null
    # Waits until the instance is fully deleted.
    aws ec2 wait instance-terminated --instance-ids "$IID"
    # Deletes the security group, which AWS only allows once the instance is gone.
    aws ec2 delete-security-group --group-id "$SG"
    # Deletes the key pair in AWS.
    aws ec2 delete-key-pair --key-name "$KEYNAME"
    # Deletes the local key file and the state file.
    rm -f "$KEY" "$STATE"
    # Lists any instance from this script that still exists. Should print nothing.
    aws ec2 describe-instances --filters Name=tag:Project,Values=$TAG \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text
    # Lists any disk from this script that still exists. Should print nothing.
    aws ec2 describe-volumes --filters Name=tag:Project,Values=$TAG \
      Name=status,Values=creating,available,in-use \
      --query 'Volumes[].VolumeId' --output text
    ;;

# Error handling: prints how to use the script if no valid stage number is given.
*)  echo "usage: bash opencsusm.sh <stage 1-8>" ;;
esac

# ===================== Stage 6 Reply =====================
# {"id":"chatcmpl-989","object":"chat.completion","created":1791588007,"model":"qwen2.5:0.5b","system_fingerprint":"fp_ollama","choices":[{"index":0,"message":{"role":"assistant","content":"Hello John! It's nice to meet you. How can I assist you today?"},"finish_reason":"stop"}],"usage":{"prompt_tokens":32,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens":18,"total_tokens":50}}
#
# ============ Stage 8 =============
# Prints nothing showing no instances or volume left.
#
