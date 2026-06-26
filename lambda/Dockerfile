# AWS Lambda Python base image (Amazon Linux, x86_64) with the runtime
# interface client already set up. Build for linux/amd64 (see deploy.ps1).
FROM public.ecr.aws/lambda/python:3.12

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Bake the DuckDB extensions (httpfs/aws) into the image so cold starts load
# them locally instead of downloading on first use.
ENV DUCKDB_EXTENSION_DIR=/opt/duckdb_extensions
COPY build_install_extensions.py /tmp/
RUN python /tmp/build_install_extensions.py && rm /tmp/build_install_extensions.py

# LAMBDA_TASK_ROOT is /var/task on the base image.
COPY app.py ${LAMBDA_TASK_ROOT}/
COPY queries/ ${LAMBDA_TASK_ROOT}/queries/

# "<module>.<function>" the runtime should invoke.
CMD ["app.handler"]
