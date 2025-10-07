#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/list_aws_resources.sh [-p PROFILE] [-r region1,region2,...]

Options:
  -p, --profile   AWS CLI profile name to use
  -r, --regions   Comma-separated list of regions to query (default: all)
  -h, --help      Show this help
EOF
}

# Check for AWS CLI
if ! command -v aws >/dev/null 2>&1; then
  echo "❌ AWS CLI not found. Please install it first."
  exit 1
fi

# Parse arguments
PROFILE=""
REGIONS_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--profile)
      [[ $# -lt 2 ]] && { echo "Missing value for $1"; usage; exit 1; }
      PROFILE="$2"; shift 2;;
    -r|--regions)
      [[ $# -lt 2 ]] && { echo "Missing value for $1"; usage; exit 1; }
      REGIONS_ARG="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1"; usage; exit 1;;
  esac
done

AWS_ARGS=()
if [[ -n "$PROFILE" ]]; then
  AWS_ARGS+=(--profile "$PROFILE")
fi

#######################################
# 1. S3 Buckets and Their Regions
#######################################

echo "📦 Fetching S3 buckets and their regions..."

buckets=$(aws "${AWS_ARGS[@]}" s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null || true)

if [[ -z "${buckets:-}" ]]; then
  echo "No S3 buckets found in this AWS account."
else
  read -r -a bucket_array <<< "$buckets"

  printf "\n%-40s | %-20s\n" "Bucket Name" "Region"
  printf "%-40s-+-%-20s\n" "$(printf '%.0s-' {1..40})" "$(printf '%.0s-' {1..20})"

  for bucket in "${bucket_array[@]}"; do
    region=$(aws "${AWS_ARGS[@]}" s3api get-bucket-location --bucket "$bucket" --query "LocationConstraint" --output text 2>/dev/null || true)

    if [[ "$region" == "None" || "$region" == "null" ]]; then
      region="us-east-1"
    elif [[ -z "${region:-}" ]]; then
      region="Unavailable or Access Denied"
    fi

    printf "%-40s | %-20s\n" "$bucket" "$region"
  done

  echo
  echo "✅ Total S3 Buckets: ${#bucket_array[@]}"
fi

#######################################
# 2. EC2 Instances with Volume Sizes
#######################################

echo
echo "🖥️ Fetching EC2 instances across all regions..."

if [[ -n "$REGIONS_ARG" ]]; then
  IFS=',' read -r -a region_array <<< "$REGIONS_ARG"
else
  regions_text=$(aws "${AWS_ARGS[@]}" ec2 describe-regions --query "Regions[].RegionName" --output text 2>/dev/null || true)
  read -r -a region_array <<< "${regions_text:-}"
fi

printf "\n%-15s | %-30s | %-20s | %-15s | %-15s\n" "Region" "Instance Name" "Instance ID" "Type" "Volume Size (GB)"
printf "%-15s-+-%-30s-+-%-20s-+-%-15s-+-%-15s\n" "$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..30})" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..15})"

total_instances=0

for region in "${region_array[@]}"; do
  # Get instance IDs in region
  instance_ids_text=$(aws "${AWS_ARGS[@]}" ec2 describe-instances --region "$region" --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
  if [[ -z "${instance_ids_text:-}" ]]; then
    continue
  fi

  read -r -a instance_ids <<< "$instance_ids_text"
  if [[ ${#instance_ids[@]} -eq 0 ]]; then
    continue
  fi

  # Build instance -> type/name maps
  declare -A instance_type_map=()
  declare -A instance_name_map=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=$'\t' read -r iid itype iname <<< "$line"
    [[ -z "${iname:-}" || "$iname" == "None" ]] && iname="N/A"
    instance_type_map["$iid"]="$itype"
    instance_name_map["$iid"]="$iname"
  done < <(aws "${AWS_ARGS[@]}" ec2 describe-instances --region "$region" --instance-ids "${instance_ids[@]}" \
        --query "Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==\`Name\`].Value|[0]]" --output text 2>/dev/null || true)

  # Map instance -> volumes and build set of unique volumes
  declare -A instance_vols_map=()
  declare -A volume_id_set=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=$'\t' read -r iid vid <<< "$line"
    [[ -z "${vid:-}" || "$vid" == "None" ]] && continue
    instance_vols_map["$iid"]+="${instance_vols_map[$iid]:+ }$vid"
    volume_id_set["$vid"]=1
  done < <(aws "${AWS_ARGS[@]}" ec2 describe-instances --region "$region" --instance-ids "${instance_ids[@]}" \
        --query "Reservations[].Instances[].[InstanceId,BlockDeviceMappings[].Ebs.VolumeId]" --output text 2>/dev/null || true)

  # Resolve volume sizes once per region in batches
  declare -A volume_size_map=()
  all_volume_ids=("${!volume_id_set[@]}")

  if [[ ${#all_volume_ids[@]} -gt 0 ]]; then
    batch_size=200
    for ((i=0; i<${#all_volume_ids[@]}; i+=batch_size)); do
      chunk=( "${all_volume_ids[@]:i:batch_size}" )
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r vid vsize <<< "$line"
        volume_size_map["$vid"]="$vsize"
      done < <(aws "${AWS_ARGS[@]}" ec2 describe-volumes --region "$region" --volume-ids "${chunk[@]}" \
            --query "Volumes[].[VolumeId,Size]" --output text 2>/dev/null || true)
    done
  fi

  # Print instance details
  for iid in "${instance_ids[@]}"; do
    itype="${instance_type_map[$iid]:-N/A}"
    iname="${instance_name_map[$iid]:-N/A}"

    total_size=0
    vols_string="${instance_vols_map[$iid]:-}"
    if [[ -n "$vols_string" ]]; then
      for vid in $vols_string; do
        size="${volume_size_map[$vid]:-0}"
        total_size=$(( total_size + size ))
      done
    fi

    printf "%-15s | %-30s | %-20s | %-15s | %-15s\n" "$region" "$iname" "$iid" "$itype" "$total_size"
    ((total_instances++))
  done

  # Cleanup associative arrays for next region
  unset instance_type_map instance_name_map instance_vols_map volume_id_set volume_size_map

done

echo
echo "✅ Total EC2 Instances: $total_instances"

#######################################
# 3. EKS Clusters
#######################################

echo
echo "☸️ Fetching EKS clusters across all regions..."

printf "\n%-30s | %-15s\n" "Cluster Name" "Region"
printf "%-30s-+-%-15s\n" "$(printf '%.0s-' {1..30})" "$(printf '%.0s-' {1..15})"

cluster_count=0

for region in "${region_array[@]}"; do
  clusters=$(aws "${AWS_ARGS[@]}" eks list-clusters --region "$region" --query "clusters[]" --output text 2>/dev/null || true)

  if [[ -z "${clusters:-}" ]]; then
    continue
  fi

  for cluster in $clusters; do
    status=$(aws "${AWS_ARGS[@]}" eks describe-cluster --name "$cluster" --region "$region" \
              --query "cluster.status" --output text 2>/dev/null || true)

    if [[ "$status" == "ACTIVE" ]]; then
      printf "%-30s | %-15s\n" "$cluster" "$region"
      ((cluster_count++))
    fi
  done

done

echo
echo "✅ Total Running EKS Clusters: $cluster_count"
