import json

def lambda_handler(event, context):
    # SQSから受け取ったイベントをログに記録
    print("Received event: ", json.dumps(event))

    # 意図的に失敗
    raise Exception("Simulated failure")

