terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

locals {
  project_name = "survey-sentiment-demo"
  lambda_source_hash = base64sha256(join("", [
    filebase64sha256("${path.module}/lambda/handler.py"),
    filebase64sha256("${path.module}/lambda/requirements.txt"),
    filebase64sha256("${path.module}/lambda/build.sh"),
  ]))
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_sqs_queue" "survey_queue" {
  name                       = "${local.project_name}-queue"
  visibility_timeout_seconds = 60
}

data "aws_iam_policy_document" "sqs_queue_policy" {
  statement {
    sid    = "AllowAPIGatewaySendMessage"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.apigw_role.arn]
    }

    actions = [
      "sqs:SendMessage",
    ]

    resources = [aws_sqs_queue.survey_queue.arn]
  }
}

resource "aws_sqs_queue_policy" "survey_queue_policy" {
  queue_url = aws_sqs_queue.survey_queue.url
  policy    = data.aws_iam_policy_document.sqs_queue_policy.json
}

resource "aws_dynamodb_table" "survey_results" {
  name         = "${local.project_name}-results"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "id"

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Project = local.project_name
  }
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${local.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid = "AllowSQSPoll"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.survey_queue.arn]
  }

  statement {
    sid = "AllowDynamoWrites"
    actions = [
      "dynamodb:PutItem",
    ]
    resources = [aws_dynamodb_table.survey_results.arn]
  }

  statement {
    sid = "AllowComprehendSentiment"
    actions = [
      "comprehend:DetectSentiment",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AllowLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "${local.project_name}-lambda-policy"
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "lambda_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

data "external" "lambda_build" {
  program = ["bash", "-c", <<-EOT
    set -e
    cd ${path.module}/lambda
    chmod +x build.sh
    ./build.sh >&2

    # Calculate hash of the created zip file (matching Terraform's filebase64sha256 format)
    if [ -f "process_survey.zip" ]; then
      # Use openssl to get raw SHA256 bytes, then base64 encode (matches Terraform's filebase64sha256)
      ZIP_HASH=$(openssl dgst -sha256 -binary process_survey.zip | base64 -w 0)
      echo "{\"status\":\"success\",\"zip_hash\":\"$ZIP_HASH\"}"
    else
      echo "{\"status\":\"error\",\"message\":\"Zip file not created\"}" >&2
      exit 1
    fi
  EOT
  ]

  query = {
    handler_hash      = filebase64sha256("${path.module}/lambda/handler.py")
    requirements_hash = filebase64sha256("${path.module}/lambda/requirements.txt")
    build_script_hash = filebase64sha256("${path.module}/lambda/build.sh")
  }
}

resource "aws_lambda_function" "process_survey" {
  function_name = "${local.project_name}-processor"
  role          = aws_iam_role.lambda_role.arn

  # Use Python 3.13 runtime
  runtime = "python3.13"
  handler = "handler.main"

  filename = "${path.module}/lambda/process_survey.zip"
  # Keep this deterministic: the zip artifact itself can change across builds due to timestamps,
  # but we only want Lambda to update when its true inputs change.
  source_code_hash = local.lambda_source_hash

  depends_on = [data.external.lambda_build]

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.survey_results.name
      REGION     = data.aws_region.current.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.survey_queue.arn
  function_name    = aws_lambda_function.process_survey.arn

  batch_size = 10
  enabled    = true
}

resource "aws_api_gateway_rest_api" "api" {
  name        = "${local.project_name}-api"
  description = "Survey submission API that posts to SQS"
}

resource "aws_api_gateway_resource" "survey" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "survey"
}

resource "aws_api_gateway_method" "post_survey" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.survey.id
  http_method   = "POST"
  authorization = "NONE"
}

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_role" {
  name               = "${local.project_name}-apigw-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json
}

data "aws_iam_policy_document" "apigw_sqs_policy" {
  statement {
    actions = [
      "sqs:SendMessage",
    ]
    resources = [aws_sqs_queue.survey_queue.arn]
  }
}

resource "aws_iam_policy" "apigw_sqs_policy" {
  name   = "${local.project_name}-apigw-sqs"
  policy = data.aws_iam_policy_document.apigw_sqs_policy.json
}

resource "aws_iam_role_policy_attachment" "apigw_sqs_attach" {
  role       = aws_iam_role.apigw_role.name
  policy_arn = aws_iam_policy.apigw_sqs_policy.arn
}

data "aws_iam_policy_document" "apigw_logs_policy" {
  count = var.enable_api_gateway_logging ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/${local.project_name}-api",
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/${local.project_name}-api:*"
    ]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "apigw_logs_policy" {
  count  = var.enable_api_gateway_logging ? 1 : 0
  name   = "${local.project_name}-apigw-logs"
  policy = data.aws_iam_policy_document.apigw_logs_policy[0].json
}

resource "aws_iam_role_policy_attachment" "apigw_logs_attach" {
  count      = var.enable_api_gateway_logging ? 1 : 0
  role       = aws_iam_role.apigw_role.name
  policy_arn = aws_iam_policy.apigw_logs_policy[0].arn
}

resource "aws_cloudwatch_log_group" "apigw_logs" {
  count             = var.enable_api_gateway_logging ? 1 : 0
  name              = "/aws/apigateway/${local.project_name}-api"
  retention_in_days = 7
}

resource "aws_api_gateway_integration" "post_survey_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.survey.id
  http_method = aws_api_gateway_method.post_survey.http_method

  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.survey_queue.name}"
  credentials             = aws_iam_role.apigw_role.arn

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }

  passthrough_behavior = "NEVER"
}

resource "aws_api_gateway_method_response" "post_survey_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.survey.id
  http_method = aws_api_gateway_method.post_survey.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "post_survey_integration_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.survey.id
  http_method = aws_api_gateway_method.post_survey.http_method
  status_code = aws_api_gateway_method_response.post_survey_200.status_code

  response_templates = {
    "application/json" = <<EOF
{"status": "success", "message": "Survey submitted successfully"}
EOF
  }

  depends_on = [
    aws_api_gateway_method.post_survey,
    aws_api_gateway_method_response.post_survey_200,
    aws_api_gateway_integration.post_survey_integration
  ]
}

resource "aws_api_gateway_method_response" "post_survey_500" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.survey.id
  http_method = aws_api_gateway_method.post_survey.http_method
  status_code = "500"
}

resource "aws_api_gateway_integration_response" "post_survey_integration_500" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.survey.id
  http_method = aws_api_gateway_method.post_survey.http_method
  status_code = aws_api_gateway_method_response.post_survey_500.status_code

  selection_pattern = ".*<ErrorResponse>.*"

  response_templates = {
    "application/json" = <<EOF
{"status":"error","message":"Failed to enqueue survey submission"}
EOF
  }

  depends_on = [
    aws_api_gateway_method.post_survey,
    aws_api_gateway_method_response.post_survey_500,
    aws_api_gateway_integration.post_survey_integration
  ]
}

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeploy = sha1(jsonencode({
      resources                = aws_api_gateway_resource.survey.id
      methods                  = aws_api_gateway_method.post_survey.id
      integration              = aws_api_gateway_integration.post_survey_integration.id
      integration_response     = aws_api_gateway_integration_response.post_survey_integration_200.id
      integration_http_method  = aws_api_gateway_integration.post_survey_integration.integration_http_method
      request_template         = aws_api_gateway_integration.post_survey_integration.request_templates["application/json"]
      integration_response_500 = aws_api_gateway_integration_response.post_survey_integration_500.id
      method_response_500      = aws_api_gateway_method_response.post_survey_500.id
      sqs_queue_policy         = aws_sqs_queue_policy.survey_queue_policy.id
    }))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_method.post_survey,
    aws_api_gateway_method_response.post_survey_200,
    aws_api_gateway_method_response.post_survey_500,
    aws_api_gateway_integration.post_survey_integration,
    aws_api_gateway_integration_response.post_survey_integration_200,
    aws_api_gateway_integration_response.post_survey_integration_500
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = "prod"
}
