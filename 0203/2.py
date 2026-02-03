from openai import OpenAI

client = OpenAI(base_url="https://ws-02.wade0426.me/v1", api_key="")

prompt = "用100字形容【人工智慧】"
temps = [0.1, 1.5]

for t in temps:
    print(f"\n測試 Temperature = {t} ...")
    try:
        response = client.chat.completions.create(
            model="Qwen/Qwen3-VL-8B-Instruct",
            messages=[
                {"role": "user", "content": prompt},
            ],
            temperature=t,
            max_tokens=100,
        )
        print(f"AI : {response.choices[0].message.content}")
    except Exception as e:
        print(e)
