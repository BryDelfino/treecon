# Use an official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.10-slim

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

# Set the working directory in the container
WORKDIR /app

# Install system dependencies required for scientific computing packages (like scipy/numpy)
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy the requirements list and install them
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
# We are assuming main.py and simulation.py are in the same directory as this Dockerfile
COPY . .

# Expose port 8080 (Cloud Run's default port)
EXPOSE 8080

# Run the web service on container startup using Uvicorn.
# Cloud Run injects the PORT environment variable, but 8080 is the default.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
