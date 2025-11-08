FROM ubuntu:22.04

LABEL maintainer="Manzolo Ubuntu Repo Manager"
LABEL description="Manzolo Ubuntu/Debian Package Repository with Aptly and Nginx"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Rome

# Install dependencies
RUN apt-get update && apt-get install -y \
    nginx \
    gnupg \
    gpg \
    wget \
    curl \
    ca-certificates \
    apt-utils \
    software-properties-common \
    bzip2 \
    xz-utils \
    gzip \
    && rm -rf /var/lib/apt/lists/*

# Add aptly repository and install aptly
RUN wget -qO - https://www.aptly.info/pubkey.txt | gpg --dearmor > /usr/share/keyrings/aptly-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/aptly-archive-keyring.gpg] http://repo.aptly.info/ squeeze main" > /etc/apt/sources.list.d/aptly.list && \
    apt-get update && \
    apt-get install -y aptly && \
    rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /var/www/manzolo-ubuntu-repo/aptly \
    /var/www/manzolo-ubuntu-repo/public \
    /var/log/nginx \
    /scripts

# Copy scripts
COPY docker-entrypoint.sh /scripts/
COPY repo-manager.sh /scripts/
RUN chmod +x /scripts/*.sh

# Nginx configuration will be created by entrypoint based on env vars
RUN rm -f /etc/nginx/sites-enabled/default

# Expose HTTP port
EXPOSE 80

# Set working directory
WORKDIR /var/www/manzolo-ubuntu-repo

# Volume for persistent data
VOLUME ["/var/www/manzolo-ubuntu-repo/aptly", "/var/www/manzolo-ubuntu-repo/public", "/root/.gnupg"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# Entrypoint
ENTRYPOINT ["/scripts/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
