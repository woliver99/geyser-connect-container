FROM docker.io/eclipse-temurin:21-jre-alpine

# Update packages and install necessary dependencies
# We need curl for downloading, jq for parsing JSON, and bash since the script uses it.
RUN apk update && \
    apk add --no-cache \
    curl \
    jq \
    bash

# Create a non-root user for the server to run as
# -D: Don't assign a password
# -h: Specify home directory
# -s: Specify shell
RUN adduser -D -h /home/container -s /bin/bash container

# Create a separate directory for server data and set ownership
# This directory is intended to be used as a bind mount point.
RUN mkdir /data && chown container:container /data

# Set the working directory for the script
WORKDIR /home/container

# Switch to the non-root user
USER container

# Copy only the update script into the container
COPY --chown=container:container update_geyser.sh .

# Make the startup script executable
RUN chmod +x ./update_geyser.sh

# Set the container's entrypoint
CMD ["/bin/bash", "./update_geyser.sh"]
