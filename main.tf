locals {
  prefix = "dlq-dev"
}

### SQS ###
resource "aws_sqs_queue" "main" {
  name                       = "${local.prefix}-sqs"
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 10
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 2
  })


  tags = {
    Name = "${local.prefix}-sqs"
  }
}

resource "aws_sqs_queue" "dlq" {
  name = "${local.prefix}-dlq"
  tags = {
    Name = "${local.prefix}-dlq"
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "queue_redrive_allow_policy" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

### Lambda ###
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "${local.prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "functions/index.py"
  output_path = "out/lambda.zip"
}

resource "aws_lambda_function" "consumer" {
  filename      = "out/lambda.zip"
  function_name = "${local.prefix}-lambda"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "index.lambda_handler"

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  runtime = "python3.13"
}

resource "aws_lambda_function_event_invoke_config" "consumer_invoke_config" {
  function_name                = aws_lambda_function.consumer.function_name
  maximum_event_age_in_seconds = 60
  maximum_retry_attempts       = 0
}

# For verification of Lambda → DLQ
data "aws_iam_policy_document" "lambda_sqs" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:SendMessage",
    ]

    resources = [aws_sqs_queue.dlq.arn]
  }
}
resource "aws_iam_policy" "lambda_sqs" {
  name        = "${local.prefix}-lambda_sqs"
  path        = "/"
  description = "IAM policy for logging from a lambda"
  policy      = data.aws_iam_policy_document.lambda_sqs.json
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.lambda_sqs.arn
}

# Logging
resource "aws_cloudwatch_log_group" "lambda_log" {
  name              = "/aws/lambda/${aws_lambda_function.consumer.function_name}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "lambda_logging" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_policy" "lambda_logging" {
  name        = "${local.prefix}-lambda_logging"
  path        = "/"
  description = "IAM policy for logging from a lambda"
  policy      = data.aws_iam_policy_document.lambda_logging.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.lambda_logging.arn
}

### StepFunctions ###

data "aws_iam_policy_document" "state_machine_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
    ]
  }
}

resource "aws_iam_role" "iam_for_state_machine" {
  name               = "${local.prefix}-state-machine"
  assume_role_policy = data.aws_iam_policy_document.state_machine_assume_role.json
}

data "aws_iam_policy_document" "state_machine_role_policy" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups"
    ]

    resources = ["${aws_cloudwatch_log_group.state_machine_logger.arn}:*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "lambda:InvokeFunction"
    ]

    resources = [aws_lambda_function.consumer.arn]
  }

}

# Create an IAM policy for the Step Functions state machine
resource "aws_iam_role_policy" "state_machine_policy" {
  name   = "${local.prefix}-state-machine-policy"
  role   = aws_iam_role.iam_for_state_machine.id
  policy = data.aws_iam_policy_document.state_machine_role_policy.json
}

# Create a Log group for the state machine
resource "aws_cloudwatch_log_group" "state_machine_logger" {
  name = "/aws/states/${local.prefix}-sfn-state-machine"
}

resource "aws_sfn_state_machine" "sfn_state_machine" {
  name     = "${local.prefix}-sfn-state-machine"
  type     = "EXPRESS"
  role_arn = aws_iam_role.iam_for_state_machine.arn
  definition = templatefile("${path.root}/statemachine/statemachine.asl.json", {
    ProcessingLambda = aws_lambda_function.consumer.arn
    }
  )
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine_logger.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
}

### EventBridge Pipes ###

data "aws_iam_policy_document" "pipe_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}
resource "aws_iam_role" "iam_for_pipe" {
  name               = "${local.prefix}-pipe"
  assume_role_policy = data.aws_iam_policy_document.pipe_assume_role.json
}

resource "aws_iam_role_policy" "source" {
  name = "${local.prefix}-source-policy"
  role = aws_iam_role.iam_for_pipe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
        ],
        Resource = [
          aws_sqs_queue.main.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "target" {
  name = "${local.prefix}-target-policy"
  role = aws_iam_role.iam_for_pipe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "states:StartSyncExecution",
          "states:StartExecution"
        ],
        Resource = [
          aws_sfn_state_machine.sfn_state_machine.arn,
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "pipe_log" {
  name = "${local.prefix}-pipe-log"
}


resource "aws_pipes_pipe" "main" {
  depends_on = [aws_iam_role_policy.source, aws_iam_role_policy.target, aws_cloudwatch_log_group.pipe_log]
  name       = "${local.prefix}-pipe"
  role_arn   = aws_iam_role.iam_for_pipe.arn
  source     = aws_sqs_queue.main.arn
  target     = aws_sfn_state_machine.sfn_state_machine.arn

  source_parameters {
    sqs_queue_parameters {
      batch_size                         = 10
      maximum_batching_window_in_seconds = 0
    }
  }
  target_parameters {
    step_function_state_machine_parameters {
      invocation_type = "REQUEST_RESPONSE"
    }
  }

  log_configuration {
    include_execution_data = ["ALL"]
    level                  = "TRACE"
    cloudwatch_logs_log_destination {
      log_group_arn = aws_cloudwatch_log_group.pipe_log.arn
    }
  }
}
