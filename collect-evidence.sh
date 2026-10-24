#!/usr/bin/env bash
# Usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>"
  exit 1
fi

BUCKET="$1"
EC2="$2"
LAMBDA="$3"

ROLL="23l-3086"
REGION="${AWS_REGION:-eu-north-1}"
EC2_ROLE="cv-ec2-role-$ROLL"
LAMBDA_ROLE="cv-lambda-role-$ROLL"
FUNC="cv-func-$ROLL"
INSTANCE_NAME="cv-ec2-$ROLL"
LOG_GROUP="/aws/lambda/$FUNC"
OUT="evidence.txt"

export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

# Accept addresses with or without scheme / trailing slash
case "$EC2" in http*) ;; *) EC2="http://$EC2" ;; esac
case "$LAMBDA" in http*) ;; *) LAMBDA="https://$LAMBDA" ;; esac
EC2="${EC2%/}"
LAMBDA="${LAMBDA%/}"

: > "$OUT"

section() { echo "" >> "$OUT"; echo "== $1 ==" >> "$OUT"; }

# Run a command; on failure, note it and carry on
run() {
  if ! "$@" >> "$OUT" 2>&1; then
    echo "FAILED: $*" >> "$OUT"
  fi
}

# Print all inline policies of a role
inline_policies() {
  local role="$1" names
  names=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>>"$OUT")
  if [ -z "$names" ] || [ "$names" = "None" ]; then
    echo "FAILED: no inline policy found on $role" >> "$OUT"
    return
  fi
  for p in $names; do
    run aws iam get-role-policy --role-name "$role" --policy-name "$p"
  done
}

section caller
echo "Collected: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$OUT"
run aws sts get-caller-identity

section public-access
run aws s3api get-public-access-block --bucket "$BUCKET"

section versioning
run aws s3api get-bucket-versioning --bucket "$BUCKET"

section objects
run aws s3 ls "s3://$BUCKET/site/" --recursive

section ec2-policy
inline_policies "$EC2_ROLE"
echo "Attached managed policies:" >> "$OUT"
run aws iam list-attached-role-policies --role-name "$EC2_ROLE"

section lambda-policy
echo "Attached managed policies:" >> "$OUT"
run aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE"
echo "Inline policies:" >> "$OUT"
inline_policies "$LAMBDA_ROLE"

IID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)

section security-group
if [ -z "$IID" ] || [ "$IID" = "None" ]; then
  echo "FAILED: no running instance named $INSTANCE_NAME" >> "$OUT"
else
  SGS=$(aws ec2 describe-instances --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text 2>>"$OUT")
  run aws ec2 describe-security-groups --group-ids $SGS \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Inbound:IpPermissions}' --output json
fi

section instance
if [ -z "$IID" ] || [ "$IID" = "None" ]; then
  echo "FAILED: no running instance named $INSTANCE_NAME" >> "$OUT"
else
  run aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].{
    InstanceId:InstanceId, Type:InstanceType, State:State.Name,
    HttpTokens:MetadataOptions.HttpTokens, HttpEndpoint:MetadataOptions.HttpEndpoint,
    InstanceProfile:IamInstanceProfile.Arn, PublicIp:PublicIpAddress, Tags:Tags}' --output json
fi

section endpoints
check() {
  local label="$1" url="$2" res
  res=$(curl -s -o /dev/null --max-time 15 -w '%{http_code} %{content_type}' "$url")
  if [ $? -ne 0 ]; then res="FAILED (curl error) $res"; fi
  echo "$label  $url  ->  $res" >> "$OUT"
}
check "EC2    " "$EC2/"
check "EC2    " "$EC2/style.css"
check "EC2    " "$EC2/cv.pdf"
check "Lambda " "$LAMBDA/"
check "Lambda " "$LAMBDA/style.css"
check "Lambda " "$LAMBDA/cv.pdf"
check "Lambda " "$LAMBDA/anything"
check "S3     " "https://$BUCKET.s3.$REGION.amazonaws.com/site/index.html"
echo "EC2 footer:    $(curl -s --max-time 15 "$EC2/" | grep -o 'Hosted on:[^<]*')" >> "$OUT"
echo "Lambda footer: $(curl -s --max-time 15 "$LAMBDA/" | grep -o 'Hosted on:[^<]*')" >> "$OUT"

# Give CloudWatch a moment to receive the log lines from the requests above
sleep 15

section lambda-logs
LOGS=$(aws logs tail "$LOG_GROUP" --since 1h --format short 2>&1)
if [ $? -ne 0 ]; then echo "FAILED: aws logs tail $LOG_GROUP" >> "$OUT"; fi
echo "$LOGS" | tail -n 20 >> "$OUT"

section log-retention
run aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[].{name:logGroupName,retentionInDays:retentionInDays}' --output json

echo "DONE"
