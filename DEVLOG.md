## 0.0 Setup AWS CLI Tools

Before we do anything - make sure you have Docker installed and the AWS CLI tools. Install the AWS CLI tools with this:

`winget install --id Amazon.AWSCLI -e`

Restart VS Code/Terminal then run this to check its working on your machine.

`aws --version`

Then run this to get your ids:

`aws sts get-caller-identity`

## 1.0 Data Ingestion Pipeline Setup

First job on this is to setup the GIS data ingestion pipeline, this is the S3 ingestion data bucket -> AWS Fargate running a docker container with a python script in it -> S3 Output/App Data bucket. Then later we will setup a lambda to trigger the python script (fargate) execution whenever new data goes into the ingestion bucket.

to start we are going to prepare some sample vector data into a geodatabase using ArcGIS Pro, this is the data prepared for this initial stage of development:

![alt text](image.png)

in the mean time it is sitting on the local disk of the dev machine (ie not in s3 bucekt yet), follow along once you have this ready.

### 1.1 Install + configure AWS CLI

First we need local tools to be able to do things into the AWS account we want to work on (make sure you have an aws account already setup via the browser/gui). 

- In terminal install the AWS tools with `winget install --id Amazon.AWSCLI -e`
- restart terminal (and vscode if you are working in there) and run `aws --version` to confirm you've got the tools working.
- next you need to login your newly installed local AWS cli tools into your AWS console. To do this, in your browser window in the `console.aws.amazon.com` 
    - click your name in the top right
    - click Security credentials
    - under Access keys section click "Create Access Key"
    - once created you will get the access key name and secret
- next, run `aws configure`
    - put in your id and secret, default region name and output format should be like this:
    ```
    AWS Access Key ID [None]: XXX------------XX
    AWS Secret Access Key [None]: XX--------------X
    Default region name [None]: ap-southeast-2
    Default output format [None]: json
    ```
- check everything is good with `aws sts get-caller-identity`

### 1.2 Create the S3 Buckets + upload the GDB

In this section we just create some S3 buckets using the CLI tools we just setup.

- Run the below commands to make 2 buckets into S3
    ```
    # pick your region once
    $REGION = "ap-southeast-2"
    $ING = "gis-poc-ingestion-intelligis"
    $APP = "gis-poc-app-intelligis"

    aws s3api create-bucket --bucket $ING --region $REGION --create-bucket-configuration LocationConstraint=$REGION
    aws s3api create-bucket --bucket $APP --region $REGION --create-bucket-configuration LocationConstraint=$REGION
    ```
- Next I just used the gui to check that the buckets were created:
    ![s3 buckets](image-1.png)
- Now using the S3 GUI in your browser, just go into the ingestion bucket and upload the whole .gdb folder into it (GDBs are made up of lots of files) once uploaded your bucket should have the gdb in it like this:
    ![ingestion gdb uploaded](image-2.png)
- Now we are ready with data to work with.

### 1.3 Setup Docker, AWS ECR and push image

Now that we have data ready, we will next setup the docker image with our process_data.py file. Look through these files to see what they do in detail but the Dockerfile defines the container that we are registering in ECR and will be used to host the data processing script that will move the data later via AWS Fargate and the process_data.py is the python code that will do the work.

- run the below to create the container registry that will house the image (remeber you got your account ID from running `aws sts get-caller-identity` earlier):
    ```
    $ACCT = "<your-account-id>"
    aws ecr create-repository --repository-name gis-poc-pipeline --region $REGION
    ```
- next, log your local docker into the new ECR (make sure you have docker installed locally ofcourse):
    ```
    $REPO = "$ACCT.dkr.ecr.$REGION.amazonaws.com/gis-poc-pipeline"

    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCT.dkr.ecr.$REGION.amazonaws.com"

    cd d:\Development\aws-gis-poc\pipeline
    docker build -t gis-poc-pipeline .
    docker tag gis-poc-pipeline:latest "${REPO}:latest"
    docker push "${REPO}:latest"
    ```
- ok your docker image is now ready in ECR so we can use it in fargate next.

### 1.4 Setup Batch compute and Fargate

next we need some roles in IAM for the batch job to run under look at the job-role-policy.json and trust-policy.json files and update them if required (ie probably the bucket names will need adjusting). Then run the below
- setup execution roll (pull image + logs):
```
aws iam create-role --role-name gisPocBatchExecutionRole --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name gisPocBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```
- setup job role (scripts s3 permissions):
```
aws iam create-role --role-name gisPocBatchJobRole --assume-role-policy-document file://trust-policy.json
aws iam put-role-policy --role-name gisPocBatchJobRole --policy-name gisPocS3Access --policy-document file://job-role-policy.json
```

- Next, we will create the compute environment which will be fargate hosted by AWS Batch. this command will need to konw a few things like the Subnet or network to create the compute resource on and the security groups that have access to execute things on it to get these value you can run this:
```
$VPC = (aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
$SUBNET = (aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query "Subnets[0].SubnetId" --output text)
$SG = (aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=default" --query "SecurityGroups[0].GroupId" --output text)
$VPC; $SUBNET; $SG
```
- that will store the required values into the variables, next we can cleanly run the create compute environment:
    ```
    aws batch create-compute-environment `
        --compute-environment-name gis-poc-ce `
        --type MANAGED `
        --compute-resources "type=FARGATE,maxvCpus=4,subnets=$SUBNET,securityGroupIds=$SG"
  ```
- next, we can check that this compute environment is valid and created by running the below command:
    ```
    aws batch describe-compute-environments `
        --compute-environments gis-poc-ce `
        --query "computeEnvironments[0].{State:state,Status:status,Reason:statusReason}" `
        --output table
    ```
    we can also check in the AWS Console on the browser under "AWS Batch":
    ![aws batch](image-3.png)
    you can see in there that we have now got compute resources assigned as an enviornment for the jobs to run on using the `Fargate` provisioning model (as opposed to EC2).

- that takes care of the compute environment - now we need the job que that will use the environment to do the work:
    ```
    aws batch create-job-queue `
        --job-queue-name gis-poc-queue `
        --priority 1 `
        --compute-environment-order "order=1,computeEnvironment=gis-poc-ce"
    ```
    now we have a job que created, this will schedule in jobs for execution. So we have the environment for jobs to execute in, we have the job que so jobs can be prioritized by AWS Batch but we don't have the actual job definition yet (like ok what job do you want me to do). the job definition for this pipeline is defined in the `job-definition.json` file, next we will register this job definition. r
- first check the job-definition.json to make sure you have the correct strings, check the account id and region particularly within these strings:
    ```
        "image": "878564871075.dkr.ecr.ap-southeast-2.amazonaws.com/gis-poc-pipeline:latest",
        "executionRoleArn": "arn:aws:iam::878564871075:role/gisPocBatchExecutionRole",
        "jobRoleArn": "arn:aws:iam::878564871075:role/gisPocBatchJobRole",
    ```
- if these are looking good register the job definition with the below:
    ```
    cd d:\Development\aws-gis-poc\pipeline\batch
    aws batch register-job-definition --cli-input-json file://job-definition.json
    ```

### 1.5 Running the job to test the loop

in the previous steps we have completed the below:
1. Created our S3 Buckets for data storage (ingestion and output app bucket)
2. built the container image and pushed it up to ECR
3. setup a compute environment, job que and job definition in AWS Batch

Now we just need to run the job to test it we can do that with:

`aws batch submit-job --job-name gis-poc-run1 --job-queue gis-poc-queue --job-definition gis-poc-job`

wath the job going with:

`aws batch list-jobs --job-queue gis-poc-queue --query "jobSummaryList[].[jobName,status]" --output table`

or in the AWS Batch console page in your browser and then check S3 app output bucket to see the data. 