FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn[standard] aiofiles

RUN apt-get update -qq && apt-get install -y -qq openssh-client && rm -rf /var/lib/apt/lists/*

COPY *.py ./
COPY static/ ./static/

RUN mkdir -p /data

EXPOSE 8200

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8200"]
