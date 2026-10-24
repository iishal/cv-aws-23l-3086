import base64
import json
import os
import time

import boto3

s3 = boto3.client("s3")

FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css"),
    "/cv.pdf": ("cv.pdf", "application/pdf"),
}

NOT_FOUND = "<html><body><h1>404 - Not Found</h1><p>No such page.</p></body></html>"


def lambda_handler(event, context):
    t0 = time.time()
    bucket = os.environ["BUCKET"]
    prefix = os.environ["PREFIX"]
    path = event.get("rawPath", "/")

    try:
        if path in FILES:
            name, ctype = FILES[path]
            data = s3.get_object(Bucket=bucket, Key=prefix + name)["Body"].read()
            headers = {"Content-Type": ctype}
            if name == "index.html":
                html = data.decode("utf-8").replace(
                    "{{HOSTED_ON}}", "Lambda " + context.function_name
                )
                headers["Cache-Control"] = "max-age=60"
                resp = {"statusCode": 200, "headers": headers, "body": html,
                        "isBase64Encoded": False}
            elif name.endswith(".pdf"):
                resp = {"statusCode": 200, "headers": headers,
                        "body": base64.b64encode(data).decode("ascii"),
                        "isBase64Encoded": True}
            else:
                resp = {"statusCode": 200, "headers": headers,
                        "body": data.decode("utf-8"), "isBase64Encoded": False}
        else:
            resp = {"statusCode": 404,
                    "headers": {"Content-Type": "text/html; charset=utf-8"},
                    "body": NOT_FOUND, "isBase64Encoded": False}
    except Exception as e:
        print("error:", repr(e))
        resp = {"statusCode": 500,
                "headers": {"Content-Type": "text/html; charset=utf-8"},
                "body": "<html><body><h1>500 - Server error</h1></body></html>",
                "isBase64Encoded": False}

    print(json.dumps({
        "fn": context.function_name,
        "path": path,
        "status": resp["statusCode"],
        "ms": int((time.time() - t0) * 1000),
    }))
    return resp
