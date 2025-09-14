# Start from the most minimal base image possible
FROM docker.io/alpine:latest

# Install all system dependencies in a single layer to optimize image size:
# - tini: A lightweight init system for containers to handle signals properly.
# - openjdk21-jre: Required to run the Geyser-Standalone.jar server.
# - python3 & py3-pip: Required to run the updater script.
RUN apk update && \
    apk add --no-cache \
    tini \
    openjdk21-jre \
    python3 \
    py3-requests

# Create a non-root user and the data directory for server files
RUN adduser -D -h /home/container -s /bin/bash container
RUN mkdir /data && chown container:container /data

# Set up the application directory
WORKDIR /app
RUN chown container:container /app
USER container

# Copy the Python application script
COPY --chown=container:container start.py .

# Use Tini as the entrypoint to handle signals and reap zombie processes
ENTRYPOINT ["/sbin/tini", "--"]

# Run the Python application as the default command
CMD ["python3", "-u", "start.py"]
