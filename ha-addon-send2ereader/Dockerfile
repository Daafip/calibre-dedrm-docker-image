FROM node:20-alpine

RUN apk add --no-cache git

# Clone send2ereader and install production dependencies
RUN git clone --depth 1 https://github.com/daniel-j/send2ereader /app \
    && cd /app \
    && sed -i 's/const expireDelay = 30/const expireDelay = 600/' index.js \
    && npm ci --production

WORKDIR /app
EXPOSE 3001

COPY run.sh /run.sh
RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]
