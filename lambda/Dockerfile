# AWS Lambda Python base image (Amazon Linux, x86_64) with the runtime
# interface client already set up. Build for linux/amd64 (see deploy.ps1).
FROM public.ecr.aws/lambda/python:3.12

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# LAMBDA_TASK_ROOT is /var/task on the base image.
COPY app.py ${LAMBDA_TASK_ROOT}/
COPY queries/ ${LAMBDA_TASK_ROOT}/queries/

# "<module>.<function>" the runtime should invoke.
CMD ["app.handler"]
