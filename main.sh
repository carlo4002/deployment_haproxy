#!/bin/bash

set -e

get_ips_postgres() {
    local regions=("eu-west-1" "eu-west-3")
    local all_entries=()

    echo "Fetching private IPs for PostgreSQL instances in specified regions..." >&2
    for region in "${regions[@]}"; do
        echo "Querying region: $region" >&2

        raw=$(aws ec2 describe-instances \
            --region "$region" \
            --filters "Name=tag:application,Values=postgres" "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[].{IP: PrivateIpAddress, Tags: Tags}' \
            --output json)

        while read -r line; do
            all_entries+=("$line")
        done < <(echo "$raw" | jq -r '
            .[] |
            {
              ip: .IP,
              tags: (reduce .Tags[] as $t ({}; .[$t.Key] = $t.Value))
            } |
            "- { name: \(.tags.Name), ip: \(.ip), etcd_node: \(.tags.etcd // "unknown") }"
        ')
    done

    printf "%s\n" "${all_entries[@]}"
}


echo "Starting Ansible inventory generation..."

# Get metadata about the current instance (where the script is running)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

echo "Getting tags for local instance..."
name=`aws ec2 describe-instances \
    --instance-ids ${INSTANCE_ID} \
    --query "Reservations[].Instances[].Tags[?Key=='Name'].Value" \
    --output text`


echo "Getting region for local instance..."
instance_az=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
    --output text)

aws_region="" # Initialize variable
if [ -z "$instance_az" ]; then
    echo "Warning: Could not determine Availability Zone for instance ID '$INSTANCE_ID'. Region variable will be empty." >&2
else
    aws_region=$(echo "$instance_az" | awk '{print substr($1, 1, length($1)-1)}')
fi
echo "Local instance region: ${aws_region}"


echo "Collecting PostgreSQL instance IPs..."
# Call the function to get all postgres IPs
#
data_collected=$(get_ips_postgres)

# Convert the space-separated string of IPs into a YAML list format for the inventory
# This uses printf to ensure each IP is on its own line and prefixed with '- ' for YAML list syntax
formatted_postgres_ips=""
if [ -n "$postgres_ips_list" ]; then
  # Replace spaces with newlines and then prefix each line with '- '
  formatted_postgres_ips=$(echo "$postgres_ips_list" | tr ' ' '\n' | sed 's/^/            - /')
else
  # If no IPs are found, ensure the list is empty or just a comment
  formatted_postgres_ips="      # No PostgreSQL IPs found"
fi


# Create an Ansible inventory file
inventory_file="ansible/inventory.yml"

# Create the inventory file using a here-document
cat <<EOF > "${inventory_file}"
all:
  hosts:
    localhost:
      ansible_connection: local
      # Variables for the localhost (control node itself)
      node_name: "${name}"
      aws_region: "${aws_region}"
      # List of PostgreSQL instance IPs gathered from AWS
      postgres_ips:
$(echo "${data_collected}" | sed 's/^/        /')
EOF

echo "---"
echo "Ansible inventory file '${inventory_file}' created successfully."
echo "---"
echo "Generated Inventory:"
echo "---"
cat "${inventory_file}"
echo "---"

cd ansible/
echo "Running Ansible playbook..."
echo "---"
echo "Ansible playbook output will be logged to /tmp/ansible.log"

ansible-playbook -i inventory.yml site.yml > /tmp/ansible.log 2>&1

if [ $? -eq 0 ]; then
    echo "Ansible playbook executed successfully."
else
    echo "Ansible playbook execution failed. Check /tmp/ansible.log for details."
fi
echo "---"
echo "Ansible playbook execution completed."