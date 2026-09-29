FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 VO1D_DB=/data/relay.sqlite3
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home relay && mkdir /data && chown relay:relay /data
COPY app.py .
USER relay
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--timeout", "45", "--limit-request-line", "4094", "--limit-request-fields", "30", "app:create_app()"]
