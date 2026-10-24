#!/bin/bash
dnf install -y httpd cronie
cat > /usr/local/bin/sync-cv.sh <<'SYNC'
#!/bin/bash
BUCKET="cv-23l-3086"
PREFIX="site/"
WEBROOT="/var/www/html"
LOG="/var/log/cv-sync.log"
export AWS_DEFAULT_REGION="eu-north-1"

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

TMP=$(mktemp -d)
if aws s3 sync "s3://${BUCKET}/${PREFIX}" "$TMP" --only-show-errors \
   && [ -f "$TMP/index.html" ]; then
  sed -i "s|{{HOSTED_ON}}|EC2 ${IID}|g" "$TMP/index.html"
  cp -rf "$TMP"/. "$WEBROOT"/
  chmod -R a+rX "$WEBROOT"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sync OK ${IID}" >> "$LOG"
else
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sync FAILED ${IID}" >> "$LOG"
fi
rm -rf "$TMP"
SYNC
chmod 755 /usr/local/bin/sync-cv.sh
echo '*/5 * * * * root /usr/local/bin/sync-cv.sh' > /etc/cron.d/cv-sync
systemctl enable --now httpd
systemctl enable --now crond
/usr/local/bin/sync-cv.sh
