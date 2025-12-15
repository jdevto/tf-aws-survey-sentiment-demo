import json
import os
import logging
import boto3
from datetime import datetime, timezone
from dateutil.relativedelta import relativedelta
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Constants
COMPREHEND_MAX_BYTES = 5000  # Comprehend limit per request
DEFAULT_LANGUAGE_CODE = 'en'

# Initialize AWS clients (outside handler for connection reuse)
dynamodb = boto3.client('dynamodb')
comprehend = boto3.client('comprehend', region_name=os.environ.get('REGION', 'ap-southeast-2'))

# Get table name from environment variable
TABLE_NAME = os.environ.get('TABLE_NAME')
if not TABLE_NAME:
    raise ValueError("TABLE_NAME environment variable is required")


def calculate_expires_at() -> int:
    """
    Calculate expires_at timestamp as 12 months from now.
    Uses relativedelta to handle month boundaries correctly.

    Returns:
        int: Unix epoch timestamp (seconds)
    """
    now = datetime.now(timezone.utc)
    expires_at = now + relativedelta(months=12)
    return int(expires_at.timestamp())


def truncate_text_for_comprehend(text: str, max_bytes: int = COMPREHEND_MAX_BYTES) -> str:
    """
    Truncate text to fit within Comprehend's byte limit.
    Comprehend has a 5000 byte limit per request.

    Args:
        text: Text to truncate
        max_bytes: Maximum bytes allowed (default: 5000)

    Returns:
        str: Truncated text that fits within byte limit
    """
    text_bytes = text.encode('utf-8')
    if len(text_bytes) <= max_bytes:
        return text

    # Truncate to fit within limit, ensuring we don't break UTF-8 characters
    truncated = text_bytes[:max_bytes]
    # Remove any incomplete UTF-8 character at the end
    while truncated and truncated[-1] & 0x80 and not (truncated[-1] & 0x40):
        truncated = truncated[:-1]

    return truncated.decode('utf-8', errors='ignore')


def process_survey_message(message_body: str) -> dict:
    """
    Process a single survey message:
    1. Parse the survey data
    2. Call Comprehend for sentiment analysis
    3. Write result to DynamoDB with TTL

    Args:
        message_body: JSON string containing survey data

    Returns:
        dict: Processing result with success status and details

    Raises:
        ValueError: If required fields are missing
        ClientError: If AWS service calls fail
        json.JSONDecodeError: If message body is invalid JSON
    """
    survey_id = None
    try:
        # Parse the message body (JSON string)
        survey_data = json.loads(message_body)

        # Extract required fields with validation
        survey_id = survey_data.get('id')
        customer_id = survey_data.get('customerId')
        survey_text = survey_data.get('surveyText', '').strip()

        if not survey_id:
            raise ValueError("Survey 'id' is required")
        if not customer_id:
            raise ValueError("Survey 'customerId' is required")
        if not survey_text:
            raise ValueError("Survey 'surveyText' is required and cannot be empty")

        # Truncate text if it exceeds Comprehend's limit
        original_length = len(survey_text)
        survey_text_truncated = truncate_text_for_comprehend(survey_text)
        if len(survey_text_truncated.encode('utf-8')) < original_length:
            logger.warning(
                f"Survey text truncated from {original_length} to {len(survey_text_truncated)} bytes for survey {survey_id}"
            )

        # Call Amazon Comprehend for sentiment analysis
        try:
            comprehend_response = comprehend.detect_sentiment(
                Text=survey_text_truncated,
                LanguageCode=DEFAULT_LANGUAGE_CODE
            )

            sentiment = comprehend_response['Sentiment']
            sentiment_scores = comprehend_response['SentimentScore']

            logger.info(
                f"Comprehend analysis for survey {survey_id}: sentiment={sentiment}, "
                f"confidence={sentiment_scores.get(sentiment, 0):.3f}"
            )

        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            logger.error(
                f"Comprehend API error for survey {survey_id}: {error_code} - {str(e)}",
                exc_info=True
            )
            raise
        except Exception as e:
            logger.error(f"Unexpected error calling Comprehend for survey {survey_id}: {str(e)}", exc_info=True)
            raise

        # Calculate TTL (12 months from now)
        expires_at = calculate_expires_at()
        created_at = datetime.now(timezone.utc).isoformat()

        # Prepare DynamoDB item
        item = {
            'id': {'S': str(survey_id)},
            'customerId': {'S': str(customer_id)},
            'surveyText': {'S': survey_text},  # Store original text, not truncated
            'sentiment': {'S': sentiment},
            'sentimentScore': {
                'M': {
                    'Positive': {'N': str(sentiment_scores.get('Positive', 0))},
                    'Negative': {'N': str(sentiment_scores.get('Negative', 0))},
                    'Neutral': {'N': str(sentiment_scores.get('Neutral', 0))},
                    'Mixed': {'N': str(sentiment_scores.get('Mixed', 0))}
                }
            },
            'created_at': {'S': created_at},
            'expires_at': {'N': str(expires_at)}
        }

        # Write to DynamoDB
        try:
            dynamodb.put_item(
                TableName=TABLE_NAME,
                Item=item
            )
            logger.info(
                f"Successfully processed survey {survey_id} (customer: {customer_id}) "
                f"with sentiment {sentiment}"
            )
            return {
                'success': True,
                'survey_id': survey_id,
                'sentiment': sentiment,
                'confidence': sentiment_scores.get(sentiment, 0)
            }
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            logger.error(
                f"DynamoDB write error for survey {survey_id}: {error_code} - {str(e)}",
                exc_info=True
            )
            raise
        except Exception as e:
            logger.error(f"Unexpected error writing to DynamoDB for survey {survey_id}: {str(e)}", exc_info=True)
            raise

    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error for survey {survey_id or 'unknown'}: {str(e)}", exc_info=True)
        raise
    except ValueError as e:
        logger.error(f"Validation error for survey {survey_id or 'unknown'}: {str(e)}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error processing survey {survey_id or 'unknown'}: {str(e)}", exc_info=True)
        raise


def main(event, context):
    """
    Lambda handler function that processes SQS events.

    Args:
        event: SQS event containing records
        context: Lambda context object

    Returns:
        dict: Processing summary with counts
    """
    records = event.get('Records', [])
    logger.info(f"Processing {len(records)} SQS record(s)")

    processed_count = 0
    failed_count = 0

    # Process each SQS record
    for i, record in enumerate(records):
        record_id = record.get('messageId', f'record-{i}')
        try:
            # Extract message body
            message_body = record.get('body', '')

            if not message_body:
                logger.warning(f"Empty message body for record {record_id}, skipping")
                failed_count += 1
                continue

            # Process the survey message
            result = process_survey_message(message_body)
            processed_count += 1

        except ValueError as e:
            # Validation errors - log but don't retry
            logger.warning(f"Validation error for record {record_id}: {str(e)}")
            failed_count += 1
        except ClientError as e:
            # AWS service errors - may be retried by SQS
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            logger.error(
                f"AWS service error for record {record_id}: {error_code} - {str(e)}",
                exc_info=True
            )
            failed_count += 1
        except Exception as e:
            # Unexpected errors
            logger.error(
                f"Unexpected error processing record {record_id}: {str(e)}",
                exc_info=True
            )
            failed_count += 1
            # Continue processing other records even if one fails
            continue

    # Log summary
    logger.info(
        f"Processing complete: {processed_count} succeeded, {failed_count} failed "
        f"(total: {len(records)})"
    )

    return {
        'statusCode': 200,
        'body': json.dumps({
            'processed': processed_count,
            'failed': failed_count,
            'total': len(records)
        })
    }
