# CV hosted on AWS — 23l-3086

**Name:** Eshal Shahid  
**Roll number:** 23l-3086  
**Region:** eu-north-1 (Europe, Stockholm)

- EC2 site: http://16.171.19.69/
- Lambda site: https://fhtelox7zcruwlrcvtyftbqde40dchuj.lambda-url.eu-north-1.on.aws/
- Bucket: `cv-23l-3086` (private)

## Architecture

```
                              Visitor (browser)
                    /                                  \
      http://16.171.19.69/              https://fhtelox7zcruwlrcvtyftbqde40dchuj
                   |                          .lambda-url.eu-north-1.on.aws/
                   |                                    |
   EC2 cv-ec2-23l-3086 (t3.micro, AL2023)    Lambda cv-func-23l-3086 (Python)
   Apache httpd serves /var/www/html         reads S3 on every request
   role: cv-ec2-role-23l-3086 (IMDSv2)       role: cv-lambda-role-23l-3086
   systemd timer -> sync-cv.sh every 5 min   JSON log line -> CloudWatch (7 days)
                   |                                    |
      s3:ListBucket (prefix site/)               s3:GetObject (site/*)
      + s3:GetObject (site/*)                           |
                    \                                  /
            S3 bucket cv-23l-3086: Block Public Access on, versioning on
                  site/index.html    site/style.css    site/cv.pdf

   Browser -> https://cv-23l-3086.s3.eu-north-1.amazonaws.com/site/index.html -> 403 AccessDenied
```

**EC2 path:** A request goes to the instance's public IP on port 80, where Apache serves the files in its web root. Those files were copied from `s3://cv-23l-3086/site/` by `sync-cv.sh`, which runs every 5 minutes with the instance role and writes the instance ID into the footer.

**Lambda path:** A request goes to the HTTPS function URL, which invokes the function. The function reads the requested object from S3 with its role, puts its own name into the footer of the page, and returns the file (the PDF base64-encoded), or a 404 page for any other path.

## Repository layout

| Path | Contents |
|---|---|
| `site/` | index.html, style.css, cv.pdf (uploaded to `s3://cv-23l-3086/site/`) |
| `ec2/user-data.sh` | Installs and starts the web server, runs the sync once, sets up the 5-minute schedule |
| `ec2/sync-cv.sh` | Syncs `site/` to the web root, replaces the placeholder, writes `/var/log/cv-sync.log` |
| `lambda/lambda_function.py` | Function code; bucket and prefix come from env vars `BUCKET` and `PREFIX` |
| `iam/` | Trust and permission policies of both roles |
| `collect-evidence.sh` | Evidence script: `./collect-evidence.sh <bucket> <ec2-address> <lambda-address>` |
| `evidence.txt` | Output of my own run of the evidence script |

## Access denied from the instance

Run from the instance through EC2 Instance Connect, using the instance role (no access keys):

```
[ec2-user@ip-172-31-33-115 ~]$ aws s3 rm s3://cv-23l-3086/site/style.css --region eu-north-1
delete failed: s3://cv-23l-3086/site/style.css An error occurred (AccessDenied) when calling the DeleteObject operation: User: arn:aws:sts::165382634412:assumed-role/cv-ec2-role-23l-3086/i-0633d461238f2c8f7 is not authorized to perform: s3:DeleteObject on resource: "arn:aws:s3:::cv-23l-3086/site/style.css" because no identity-based policy allows the s3:DeleteObject action

[ec2-user@ip-172-31-33-115 ~]$ aws s3 cp /tmp/t.txt s3://cv-23l-3086/site/style.css --region eu-north-1
upload failed: ../../tmp/t.txt to s3://cv-23l-3086/site/style.css An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:sts::165382634412:assumed-role/cv-ec2-role-23l-3086/i-0633d461238f2c8f7 is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::cv-23l-3086/site/style.css" because no identity-based policy allows the s3:PutObject action
```

## Last 10 lines of /var/log/cv-sync.log

```
2026-10-24T16:35:02Z sync OK i-0633d461238f2c8f7
2026-10-24T16:40:02Z sync OK i-0633d461238f2c8f7
2026-10-24T16:45:01Z sync OK i-0633d461238f2c8f7
2026-10-24T16:50:02Z sync OK i-0633d461238f2c8f7
2026-10-24T16:55:02Z sync OK i-0633d461238f2c8f7
2026-10-24T17:00:02Z sync OK i-0633d461238f2c8f7
2026-10-24T17:05:01Z sync OK i-0633d461238f2c8f7
2026-10-24T17:10:02Z sync OK i-0633d461238f2c8f7
2026-10-24T17:15:02Z sync OK i-0633d461238f2c8f7
2026-10-24T17:20:02Z sync OK i-0633d461238f2c8f7
```

## Written answers

**1. Why do the instance and the function use roles instead of access keys? What could go wrong if the keys were in the user data?**  
A role gives the instance and the function temporary credentials that AWS creates and rotates automatically, valid only for that resource and only for the actions in the role's policy. Nothing long-lived is stored, so there is nothing to leak or forget to rotate. User data is not secret: anyone allowed to describe the instance can read it, and any process on the instance can fetch it from the metadata service. Here `user-data.sh` is also in a public GitHub repository, and bots scan GitHub for keys within minutes. Leaked keys keep working until someone deactivates them, so an attacker could read or delete data or start expensive resources on the account.

**2. Someone pastes the S3 address of index.html into a browser. What do they see, and which setting causes that?**  
They get HTTP 403 with an XML `AccessDenied` error instead of the CV. The browser sends the request without any credentials, and nothing in the bucket allows anonymous reads: there is no bucket policy and no public ACL. The four Block Public Access settings make sure it stays that way, because they would block a public policy or ACL even if one were added by mistake.

**3. Explain the permission on the function URL that lets anyone call it. Why is that acceptable for the function but not for the bucket?**  
The function has a resource-based policy with principal `*` that allows `lambda:InvokeFunctionUrl` on the condition that the URL's auth type is NONE, so any unauthenticated HTTPS request to the URL may run the function. That is acceptable because the function's code decides exactly what is returned: four fixed files, read-only, and a 404 for anything else, while its own role can only read objects under `site/`. A public bucket would expose every object and every old version directly, with no code in between to limit paths, set headers, log requests, or hide something uploaded by mistake.

**4. Compare the two paths. What do you pay for when nobody visits the site? What happens if the traffic grows a hundred times?**  
With no visitors, EC2 still costs money for every hour the instance runs, for its EBS volume and for its public IPv4 address (currently covered by Free Tier and credits). Lambda costs nothing while idle, so only the small S3 storage and CloudWatch log costs remain. At a hundred times the traffic, one t3.micro can run out of CPU credits or bandwidth, and with no load balancer or auto scaling the site slows down or fails. Lambda starts more copies on its own up to the account's concurrency limit, and its cost simply grows with the number of requests and S3 reads.

**5. You delete the EC2 instance. What do you lose and what do you still have?**  
I lose the running web server and its public IP address, which I cannot get back because it is not an Elastic IP. I also lose the root volume, which is deleted on termination by default, along with the copy of the site, `/var/log/cv-sync.log` and the timer setup. I still have the bucket with all files and versions, the IAM role and instance profile, the security group, and the Lambda site, which keeps working. Because `user-data.sh` and `sync-cv.sh` are in this repository, a new instance can rebuild the EC2 site in a few minutes, just at a new address.

## Sources and acknowledgements

- Course material for the DevOps course.
- AWS documentation: S3 Block Public Access, IAM roles for Amazon EC2, Lambda execution role, Lambda function URLs, EC2 instance metadata (IMDSv2), Amazon Linux 2023 (systemd timers), AWS IP address ranges (EC2 Instance Connect).
- All resources were set up and tested in my own AWS account; the policies and scripts follow the patterns in the AWS documentation, adapted to my bucket, role and function names.
