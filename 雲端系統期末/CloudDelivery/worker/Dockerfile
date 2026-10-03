FROM python:3.9-slim

# 安裝 procps 套件以支援 top 指令
RUN apt-get update && apt-get install -y procps && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker.py .
CMD ["python","-u", "worker.py"]