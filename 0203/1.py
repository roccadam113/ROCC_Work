from openai import OpenAI

client = OpenAI(base_url="https://ws-02.wade0426.me/v1", api_key="")

while True:
    user_input = input("Input:")
    if user_input.lower() in ["q", "exit"]:
        print("end")
        break

    response = client.chat.completions.create(
        model="Qwen/Qwen3-VL-8B-Instruct",
        messages=[
            {"role": "system", "content": "你是一個繁體中文聊天機器人，會簡易回答"},
            {"role": "user", "content": user_input},
        ],
        temperature=0.7,
        max_tokens=256,
    )
    print(f"AI: {response.choices[0].message.content}")
