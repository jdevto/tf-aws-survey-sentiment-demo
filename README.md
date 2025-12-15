# tf-aws-survey-sentiment-demo

Example Terraform setup for survey ingestion using API Gateway, SQS, Lambda, Comprehend, and DynamoDB TTL.

## Architecture

This solution implements a scalable survey sentiment analysis system:

```plaintext
Website Survey Form
    ↓ (POST JSON)
API Gateway REST API
    ↓ (writes to)
SQS Queue
    ↓ (triggers)
Lambda Function
    ↓ (calls)
Amazon Comprehend (sentiment analysis)
    ↓ (writes results to)
DynamoDB Table (with 12-month TTL)
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Python 3.13 (or 3.12 if 3.13 is not available in your region)
- pip for installing Python dependencies

## Setup Instructions

### 1. Configure AWS Region (Optional)

The default region is set to `ap-southeast-2` in `main.tf`. To change it, edit the `provider "aws"` block in `main.tf`.

**Note**: Python 3.13 may not be available in all AWS regions yet. If deployment fails with a runtime error, change the runtime to `python3.12` in `main.tf` (line with `runtime = "python3.13"`).

**Note**: The Lambda package is built automatically by Terraform before deployment. The build script requires `pip` and `zip` to be available on your system.

### 2. Deploy with Terraform

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply the configuration
terraform apply
```

After deployment, Terraform will output:

- `api_invoke_url` - The API Gateway endpoint URL for submitting surveys
- `dynamodb_table_name` - The DynamoDB table name
- `sqs_queue_url` - The SQS queue URL
- `lambda_function_name` - The Lambda function name

### 3. Test the API

You can test the survey submission endpoint using curl. After deployment, Terraform will output a ready-to-use curl command:

```bash
# Get the curl command from Terraform output
terraform output -raw curl_example
```

Or use the endpoint URL directly:

```bash
# Get the endpoint URL
ENDPOINT=$(terraform output -raw survey_endpoint)

# Test the API
curl -X POST $ENDPOINT \
  -H "Content-Type: application/json" \
  -d '{
    "id": "survey-001",
    "customerId": "customer-123",
    "surveyText": "I love this product! It works perfectly and the customer service is excellent."
  }'
```

Expected response:

```json
{"status": "success", "message": "Survey submitted successfully"}
```

**Important**: This API is **asynchronous**. A 200 response means the survey was **enqueued to SQS**, not that sentiment has already been written to DynamoDB.

**Also note**: DynamoDB uses `id` as the partition key. Re-using the same `id` will overwrite the same item (it will not create a “new row”).

## Survey Data Format

The API expects JSON payloads with the following structure:

```json
{
  "id": "unique-survey-id",
  "customerId": "customer-identifier",
  "surveyText": "The survey text to analyze for sentiment"
}
```

## DynamoDB Schema

Survey results are stored in DynamoDB with the following structure:

- `id` (String) - Partition key, unique survey identifier
- `customerId` (String) - Customer identifier
- `surveyText` (String) - Original survey text
- `sentiment` (String) - Detected sentiment: POSITIVE, NEGATIVE, NEUTRAL, or MIXED
- `sentimentScore` (Map) - Confidence scores for each sentiment type
  - `Positive` (Number)
  - `Negative` (Number)
  - `Neutral` (Number)
  - `Mixed` (Number)
- `created_at` (String) - ISO 8601 timestamp
- `expires_at` (Number) - Unix epoch seconds (12 months from creation)

## TTL (Time To Live)

The DynamoDB table uses TTL to automatically delete records after 12 months. The `expires_at` attribute is calculated as exactly 12 months from the record creation time, accounting for month boundaries correctly.

**Note**: DynamoDB TTL deletion is eventually consistent. Items may persist slightly beyond their expiration time.

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

## End-to-end verification (recommended)

The API is asynchronous: `POST /survey` enqueues to SQS, then Lambda processes and writes results to DynamoDB.

To verify the full flow end-to-end:

```bash
./scripts/e2e.sh
```

Or manually, after a POST:

```bash
# Replace SURVEY_ID with your posted id
aws dynamodb get-item \
  --region ap-southeast-2 \
  --table-name "$(terraform output -raw dynamodb_table_name)" \
  --consistent-read \
  --key "{\"id\":{\"S\":\"SURVEY_ID\"}}"
```

## Repo hygiene notes

- **`lambda/process_survey.zip`** is a **build artifact** and is rebuilt automatically during `terraform plan/apply` (see `lambda/build.sh`).
- **`terraform.tfstate*`** is **local state** and should not be committed; use a remote backend (S3 + DynamoDB) for shared/team deployments.

## Troubleshooting

### Lambda Runtime Error

If you see an error about Python 3.13 not being available:

1. Edit `main.tf`
2. Change `runtime = "python3.13"` to `runtime = "python3.12"`
3. Run `terraform apply` again

### Lambda Build Fails

If the automatic Lambda build fails during `terraform apply`:

- Ensure `pip` is installed and available in your PATH
- Ensure `zip` is installed (usually pre-installed on Linux/macOS)
- Check that Python 3.13 (or your chosen runtime) is available
- The build script runs automatically, so no manual build step is needed

### API Gateway Returns 500

Check CloudWatch Logs for the Lambda function to see error details. Common issues:

- Missing required fields in survey payload
- Comprehend API errors (check IAM permissions)
- DynamoDB write errors

## License

MIT License - see LICENSE file for details.
