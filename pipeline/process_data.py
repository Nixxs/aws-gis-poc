"""POC data pipeline - step 1.

Goal of this version: prove that the AWS Batch container can READ from the
ingestion bucket and WRITE to the application bucket.

It copies every object from the source location to the destination location.
Later this script will be extended to convert:
    File GDB   -> GeoParquet / PMTiles
    GeoTIFF    -> COG (Cloud Optimized GeoTIFF)

Configuration comes from environment variables (set on the Batch job):
    INGESTION_BUCKET  (required)  source S3 bucket
    APP_BUCKET        (required)  destination S3 bucket
    SOURCE_PREFIX     (optional)  only copy objects under this prefix (default: "")
    DEST_PREFIX       (optional)  prefix to write under in the app bucket (default: "raw/")
"""

import logging
import os
import sys

import boto3

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("process_data")


def get_env(name: str, default: str = "", required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        log.error("Missing required environment variable: %s", name)
        sys.exit(1)
    return value


def main() -> None:
    ingestion_bucket = get_env("INGESTION_BUCKET", required=True)
    app_bucket = get_env("APP_BUCKET", required=True)
    source_prefix = get_env("SOURCE_PREFIX", default="")
    dest_prefix = get_env("DEST_PREFIX", default="raw/")

    log.info(
        "Starting copy: s3://%s/%s -> s3://%s/%s",
        ingestion_bucket,
        source_prefix,
        app_bucket,
        dest_prefix,
    )

    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")

    copied = 0
    for page in paginator.paginate(Bucket=ingestion_bucket, Prefix=source_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/"):
                continue  # skip "folder" placeholder objects

            relative_key = key[len(source_prefix):].lstrip("/")
            dest_key = dest_prefix + relative_key

            log.info("Copying %s (%s bytes) -> %s", key, obj["Size"], dest_key)
            s3.copy_object(
                CopySource={"Bucket": ingestion_bucket, "Key": key},
                Bucket=app_bucket,
                Key=dest_key,
            )
            copied += 1

    if copied == 0:
        log.warning("No objects found under s3://%s/%s", ingestion_bucket, source_prefix)
    else:
        log.info("Done. Copied %d object(s) to s3://%s/%s", copied, app_bucket, dest_prefix)


if __name__ == "__main__":
    main()
