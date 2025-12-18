output "api_invoke_url" {
  description = "API Gateway invoke URL"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/survey"
}

output "survey_endpoint" {
  description = "Full survey submission endpoint URL"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/survey"
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for survey results"
  value       = aws_dynamodb_table.survey_results.name
}

output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = aws_sqs_queue.survey_queue.url
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.process_survey.function_name
}
