# sqs-dlq-validation
EventBridge Pipes を利用して、SQS から DLQ への流れを確認する

## SQS → Lambda（同期）

https://github.com/shikazuki/sqs-dlq-validation/commit/792209ae153b6d72e45cd8fd600dc2230d391854 にて実装。

しかし、可視性タイムアウトが30秒にも関わらず、15分程度経過によって動作し、DLQに入る結果となってしまった。

```tf
  source_parameters {
    sqs_queue_parameters {
      batch_size                         = 1
-      maximum_batching_window_in_seconds = 2
+      maximum_batching_window_in_seconds = 0
    }
  }
```
maximum_batching_window_in_seconds を 0 にすることで正しく動作するように変わった

## SQS → StepFunctions（同期）

https://github.com/shikazuki/sqs-dlq-validation/commit/be505a6879fbe17068d6fb81752227633277aa11
