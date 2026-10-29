FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
RUN useradd --uid 10001 --create-home vocab && mkdir -p /data && chown vocab /data
USER vocab
ENV VOCAB_SYNC_DB=/data/vocab-sync.sqlite
EXPOSE 8095
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8095", "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header"]
