from openai import OpenAI
import json

client = OpenAI(base_url="https://ws-02.wade0426.me/v1", api_key="")
inputs = "我是ROCC，電話 123-456-789，2 個 鉛筆，明天下午到臺中"
prompt = "你是資料提取助手，從user文字提取資訊，並嚴格用 JSON 格式回應。需要的欄位：name . phone , product , quantity , address"
try:
    response = client.chat.completions.create(
        model="Qwen/Qwen3-VL-8B-Instruct",
        messages=[
            {"role": "system", "content": prompt},
            {"role": "user", "content": inputs},
        ],
        temperature=0.1,
    )
    json_reply = response.choices[0].message.content
    if json_reply:
        clean_json = json_reply.replace("```json", "").replace("```", "").strip()
        decision = json.loads(clean_json)
        print(json.dumps(decision, ensure_ascii=False, indent=2))
    else:
        raise Exception("空的")
except Exception as e:
    print(e)
