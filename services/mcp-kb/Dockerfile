# file: services/mcp-kb/Dockerfile   (no file extension)
FROM python:3.12-slim
# unbuffered so `docker compose logs` shows output immediately while debugging
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
USER nobody
EXPOSE 8080
CMD ["python", "server.py"]
