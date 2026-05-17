FROM node:20-alpine
WORKDIR /app
COPY server.js .
ENV PORT=3001
ENV DATA_DIR=/data
EXPOSE 3001
# Ensure /data is writable for the node user even when Docker volume is mounted
RUN mkdir -p /data && chown -R node:node /data
USER node
CMD ["node", "server.js"]
