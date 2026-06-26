"""list-layers: the available layers are simply the .parquet objects the
pipeline wrote under the GeoParquet prefix in the app bucket.

This needs no parquet reading - just an S3 listing - so it has no heavy deps.
"""

import boto3

s3 = boto3.client("s3")


def list_layers(bucket: str, prefix: str) -> list:
    paginator = s3.get_paginator("list_objects_v2")
    layers = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".parquet"):
                name = key.rsplit("/", 1)[-1][: -len(".parquet")]
                layers.append(name)
    return sorted(layers)
